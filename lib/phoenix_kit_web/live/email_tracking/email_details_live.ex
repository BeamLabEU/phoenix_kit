defmodule PhoenixKitWeb.Live.EmailTracking.EmailDetailsLive do
  @moduledoc """
  LiveView for displaying detailed information about a specific email log.

  Provides comprehensive view of email metadata, delivery status, events timeline,
  and performance analytics for individual emails.

  ## Features

  - **Complete Email Metadata**: Headers, size, attachments, template info
  - **Events Timeline**: Chronological view of all email events
  - **Delivery Status**: Real-time status tracking and updates
  - **Geographic Data**: Location info for opens and clicks
  - **Performance Metrics**: Individual email analytics
  - **Debugging Info**: Technical details for troubleshooting
  - **Related Emails**: Other emails in same campaign/template

  ## Route

  This LiveView is mounted at `{prefix}/admin/email-logs/:id` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

      # In your Phoenix router
      live "/email-logs/:id", PhoenixKitWeb.Live.EmailTracking.EmailDetailsLive, :show

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  require Logger
  import PhoenixKitWeb.CoreComponents

  alias PhoenixKit.EmailTracking
  alias PhoenixKit.EmailTracking.EmailLog
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(%{"id" => id}, session, socket) do
    # Check if email tracking is enabled
    if EmailTracking.enabled?() do
      case Integer.parse(id) do
        {email_id, _} ->
          # Get current path for navigation
          current_path = get_current_path(socket, session, email_id)

          # Get project title from settings
          project_title = Settings.get_setting("project_title", "PhoenixKit")

          socket =
            socket
            |> assign(:email_id, email_id)
            |> assign(:current_path, current_path)
            |> assign(:project_title, project_title)
            |> assign(:email_log, nil)
            |> assign(:events, [])
            |> assign(:related_emails, [])
            |> assign(:loading, true)
            |> load_email_data()

          {:ok, socket}

        _ ->
          {:ok,
           socket
           |> put_flash(:error, "Invalid email ID")
           |> push_navigate(to: Routes.path("/admin/email-logs"))}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Email tracking is not enabled")
       |> push_navigate(to: Routes.path("/admin/email-logs"))}
    end
  end

  ## --- Event Handlers ---

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_email_data()}
  end

  @impl true
  def handle_event("toggle_headers", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_headers, !Map.get(socket.assigns, :show_headers, false))}
  end

  @impl true
  def handle_event("toggle_body", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_body, !Map.get(socket.assigns, :show_body, false))}
  end

  @impl true
  def handle_event("export_details", _params, socket) do
    # Export email details as JSON
    email_data = %{
      email_log: socket.assigns.email_log,
      events: socket.assigns.events,
      exported_at: DateTime.utc_now()
    }

    filename = "email_#{socket.assigns.email_id}_details.json"
    json_content = Jason.encode!(email_data, pretty: true)

    {:noreply,
     socket
     |> push_event("download", %{
       filename: filename,
       content: json_content,
       mime_type: "application/json"
     })}
  end

  @impl true
  def handle_event("view_related", %{"campaign_id" => campaign_id}, socket) do
    {:noreply,
     socket
     |> push_navigate(to: Routes.path("/admin/email-logs?campaign_id=#{campaign_id}"))}
  end

  @impl true
  def handle_event("view_related", %{"template_name" => template_name}, socket) do
    {:noreply,
     socket
     |> push_navigate(to: Routes.path("/admin/email-logs?template_name=#{template_name}"))}
  end

  ## --- Template ---

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={"Email #{@email_id}"}
      current_path={@current_path}
      project_title={@project_title}
    >
      <div class="container flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <%!-- Back Button (Left aligned) --%>
          <.link
            navigate={Routes.path("/admin/email-logs")}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0 -mb-12"
          >
            <.icon_arrow_left /> Back to Email Logs
          </.link>

          <%!-- Title Section --%>
          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">
              Email Details #{@email_id}
            </h1>
            <%= if @email_log do %>
              <p class="text-lg text-base-content">{@email_log.to}</p>
            <% end %>
          </div>
        </header>

        <%!-- Main Content --%>
        <div class="email-details-container">
          <%= if @loading do %>
            <div class="flex justify-center items-center h-32">
              <span class="loading loading-spinner loading-md"></span>
              <span class="ml-2">Loading email details...</span>
            </div>
          <% else %>
            <%= if @email_log do %>
              <%!-- Page Header with Actions --%>
              <div class="flex flex-col lg:flex-row lg:items-center lg:justify-between mb-6">
                <div>
                  <h1 class="text-2xl font-bold text-base-content mb-2">
                    Email Details #{@email_log.id}
                  </h1>
                  <div class="flex items-center gap-4 text-sm text-base-content/70">
                    <span>To: {@email_log.to}</span>
                    <span>•</span>
                    <span>
                      Status:
                      <span class={status_badge_class(@email_log.status)}>{@email_log.status}</span>
                    </span>
                    <span>•</span>
                    <span>
                      Sent: {UtilsDate.format_datetime_with_user_format(@email_log.sent_at)}
                    </span>
                  </div>
                </div>

                <div class="flex gap-2 mt-4 lg:mt-0">
                  <button phx-click="export_details" class="btn btn-outline btn-sm">
                    <.icon name="hero-arrow-down-tray" class="w-4 h-4 mr-1" /> Export
                  </button>

                  <button phx-click="refresh" class="btn btn-outline btn-sm">
                    <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" /> Refresh
                  </button>
                </div>
              </div>

              <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
                <%!-- Main Content Column --%>
                <div class="lg:col-span-2 space-y-6">
                  <%!-- Email Overview Card --%>
                  <div class="card bg-base-100 shadow-sm">
                    <div class="card-body">
                      <h2 class="card-title text-lg mb-4">Email Overview</h2>

                      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                        <div class="space-y-3">
                          <div>
                            <label class="text-sm font-medium text-base-content/70">Subject</label>
                            <p class="text-sm">{@email_log.subject || "(no subject)"}</p>
                          </div>

                          <div>
                            <label class="text-sm font-medium text-base-content/70">From</label>
                            <p class="text-sm">{@email_log.from}</p>
                          </div>

                          <div>
                            <label class="text-sm font-medium text-base-content/70">To</label>
                            <p class="text-sm">{@email_log.to}</p>
                          </div>

                          <%= if @email_log.template_name do %>
                            <div>
                              <label class="text-sm font-medium text-base-content/70">Template</label>
                              <div class="flex items-center gap-2">
                                <span class="badge badge-primary badge-sm">
                                  {@email_log.template_name}
                                </span>
                                <button
                                  phx-click="view_related"
                                  phx-value-template_name={@email_log.template_name}
                                  class="text-xs text-blue-600 hover:underline"
                                >
                                  View related emails
                                </button>
                              </div>
                            </div>
                          <% end %>
                        </div>

                        <div class="space-y-3">
                          <div>
                            <label class="text-sm font-medium text-base-content/70">Status</label>
                            <div class={status_badge_class(@email_log.status)}>
                              {@email_log.status}
                            </div>
                          </div>

                          <div>
                            <label class="text-sm font-medium text-base-content/70">Provider</label>
                            <div class="badge badge-outline badge-sm">{@email_log.provider}</div>
                          </div>

                          <div>
                            <label class="text-sm font-medium text-base-content/70">Size</label>
                            <p class="text-sm">{format_bytes(@email_log.size_bytes)}</p>
                          </div>

                          <div>
                            <label class="text-sm font-medium text-base-content/70">
                              Attachments
                            </label>
                            <p class="text-sm">{@email_log.attachments_count}</p>
                          </div>
                        </div>
                      </div>

                      <%= if @email_log.campaign_id do %>
                        <div class="border-t pt-4 mt-4">
                          <label class="text-sm font-medium text-base-content/70">Campaign</label>
                          <div class="flex items-center gap-2 mt-1">
                            <span class="badge badge-secondary badge-sm">
                              {@email_log.campaign_id}
                            </span>
                            <button
                              phx-click="view_related"
                              phx-value-campaign_id={@email_log.campaign_id}
                              class="text-xs text-blue-600 hover:underline"
                            >
                              View campaign emails
                            </button>
                          </div>
                        </div>
                      <% end %>

                      <%= if @email_log.error_message do %>
                        <div class="alert alert-error mt-4">
                          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                          <div>
                            <strong>Error:</strong> {@email_log.error_message}
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>

                  <%!-- Email Content Card --%>
                  <div class="card bg-base-100 shadow-sm">
                    <div class="card-body">
                      <div class="flex items-center justify-between mb-4">
                        <h2 class="card-title text-lg">Email Content</h2>
                        <div class="flex gap-2">
                          <%= if @email_log.body_full do %>
                            <button
                              phx-click="toggle_body"
                              class="btn btn-outline btn-sm"
                            >
                              {if assigns[:show_body], do: "Hide", else: "Show"} Full Body
                            </button>
                          <% end %>
                          <button
                            phx-click="toggle_headers"
                            class="btn btn-outline btn-sm"
                          >
                            {if assigns[:show_headers], do: "Hide", else: "Show"} Headers
                          </button>
                        </div>
                      </div>

                      <%!-- Body Preview --%>
                      <div class="mb-4">
                        <label class="text-sm font-medium text-base-content/70 block mb-2">
                          Body Preview
                        </label>
                        <div class="bg-base-200 p-3 rounded text-sm max-h-40 overflow-y-auto">
                          <%= if @email_log.body_preview do %>
                            <pre class="whitespace-pre-wrap"><%= @email_log.body_preview %></pre>
                          <% else %>
                            <em class="text-base-content/60">No preview available</em>
                          <% end %>
                        </div>
                      </div>

                      <%!-- Full Body (collapsible) --%>
                      <%= if assigns[:show_body] and @email_log.body_full do %>
                        <div class="mb-4">
                          <label class="text-sm font-medium text-base-content/70 block mb-2">
                            Full Body
                          </label>
                          <div class="bg-base-200 p-3 rounded text-sm max-h-60 overflow-y-auto">
                            <pre class="whitespace-pre-wrap"><%= @email_log.body_full %></pre>
                          </div>
                        </div>
                      <% end %>

                      <%!-- Headers (collapsible) --%>
                      <%= if assigns[:show_headers] and @email_log.headers && map_size(@email_log.headers) > 0 do %>
                        <div>
                          <label class="text-sm font-medium text-base-content/70 block mb-2">
                            Headers
                          </label>
                          <div class="bg-base-200 p-3 rounded text-sm max-h-40 overflow-y-auto">
                            <table class="table-auto w-full text-xs">
                              <thead>
                                <tr class="border-b">
                                  <th class="text-left py-1 pr-4">Header</th>
                                  <th class="text-left py-1">Value</th>
                                </tr>
                              </thead>
                              <tbody>
                                <%= for {key, value} <- @email_log.headers do %>
                                  <tr class="border-b border-gray-200">
                                    <td class="py-1 pr-4 font-medium">{key}</td>
                                    <td class="py-1 break-all">{value}</td>
                                  </tr>
                                <% end %>
                              </tbody>
                            </table>
                          </div>
                        </div>
                      <% end %>

                      <%!-- Show message when headers are empty but toggle is on --%>
                      <%= if assigns[:show_headers] and (is_nil(@email_log.headers) or map_size(@email_log.headers) == 0) do %>
                        <div>
                          <label class="text-sm font-medium text-base-content/70 block mb-2">
                            Headers
                          </label>
                          <div class="bg-base-200 p-3 rounded text-sm text-base-content/60 italic">
                            No headers available for this email
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>

                  <%!-- Events Timeline --%>
                  <div class="card bg-base-100 shadow-sm">
                    <div class="card-body">
                      <h2 class="card-title text-lg mb-4">Events Timeline</h2>

                      <%= if length(@events) > 0 do %>
                        <div class="timeline">
                          <%= for {event, index} <- Enum.with_index(@events) do %>
                            <div class="timeline-item">
                              <div class="timeline-marker">
                                <div class={event_marker_class(event.event_type)}>
                                  <.icon name={event_icon(event.event_type)} class="w-3 h-3" />
                                </div>
                              </div>

                              <div class="timeline-content">
                                <div class="flex items-center justify-between mb-1">
                                  <h4 class="font-medium text-sm">
                                    {format_event_title(event.event_type)}
                                  </h4>
                                  <time class="text-xs text-base-content/60">
                                    {UtilsDate.format_datetime_with_user_format(event.occurred_at)}
                                  </time>
                                </div>

                                {render_event_details(event)}
                              </div>
                            </div>
                          <% end %>
                        </div>
                      <% else %>
                        <div class="text-center py-8 text-base-content/60">
                          <.icon
                            name="hero-clock"
                            class="w-12 h-12 mx-auto mb-2 text-base-content/30"
                          />
                          <p>No events recorded for this email</p>
                        </div>
                      <% end %>
                    </div>
                  </div>
                </div>

                <%!-- Sidebar --%>
                <div class="space-y-6">
                  <%!-- Quick Stats --%>
                  <div class="card bg-base-100 shadow-sm">
                    <div class="card-body">
                      <h3 class="card-title text-base mb-4">Quick Stats</h3>

                      <div class="stats stats-vertical shadow-none bg-transparent">
                        <div class="stat px-0 py-2">
                          <div class="stat-title text-xs">Message ID</div>
                          <div class="stat-value text-xs font-mono break-all">
                            {@email_log.message_id}
                          </div>
                        </div>

                        <div class="stat px-0 py-2">
                          <div class="stat-title text-xs">Sent At</div>
                          <div class="stat-value text-sm">
                            {UtilsDate.format_datetime_with_user_format(@email_log.sent_at)}
                          </div>
                        </div>

                        <%= if @email_log.delivered_at do %>
                          <div class="stat px-0 py-2">
                            <div class="stat-title text-xs">Delivered At</div>
                            <div class="stat-value text-sm">
                              {UtilsDate.format_datetime_with_user_format(@email_log.delivered_at)}
                            </div>
                            <div class="stat-desc text-xs">
                              {format_duration(@email_log.sent_at, @email_log.delivered_at)} delivery time
                            </div>
                          </div>
                        <% end %>

                        <div class="stat px-0 py-2">
                          <div class="stat-title text-xs">Events</div>
                          <div class="stat-value text-lg">{length(@events)}</div>
                        </div>

                        <%= if @email_log.retry_count > 0 do %>
                          <div class="stat px-0 py-2">
                            <div class="stat-title text-xs">Retries</div>
                            <div class="stat-value text-lg text-warning">
                              {@email_log.retry_count}
                            </div>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <%!-- Message Tags --%>
                  <%= if map_size(@email_log.message_tags) > 0 do %>
                    <div class="card bg-base-100 shadow-sm">
                      <div class="card-body">
                        <h3 class="card-title text-base mb-4">Message Tags</h3>

                        <div class="space-y-2">
                          <%= for {key, value} <- @email_log.message_tags do %>
                            <div class="flex justify-between items-center text-sm">
                              <span class="font-medium">{key}</span>
                              <span class="badge badge-outline badge-xs">{value}</span>
                            </div>
                          <% end %>
                        </div>
                      </div>
                    </div>
                  <% end %>

                  <%!-- Related Emails --%>
                  <%= if length(@related_emails) > 0 do %>
                    <div class="card bg-base-100 shadow-sm">
                      <div class="card-body">
                        <h3 class="card-title text-base mb-4">Related Emails</h3>

                        <div class="space-y-2">
                          <%= for related <- Enum.take(@related_emails, 5) do %>
                            <.link
                              navigate={Routes.path("/admin/email-logs/#{related.id}")}
                              class="block p-2 rounded hover:bg-base-200 text-sm"
                            >
                              <div class="font-medium truncate">{related.to}</div>
                              <div class="text-xs text-base-content/60 flex items-center justify-between">
                                <span>
                                  {UtilsDate.format_datetime_with_user_format(related.sent_at)}
                                </span>
                                <span class={status_badge_class(related.status, "badge-xs")}>
                                  {related.status}
                                </span>
                              </div>
                            </.link>
                          <% end %>

                          <%= if length(@related_emails) > 5 do %>
                            <div class="text-center pt-2">
                              <button
                                phx-click="view_related"
                                phx-value-campaign_id={@email_log.campaign_id}
                                class="text-xs text-blue-600 hover:underline"
                              >
                                View all {length(@related_emails)} related emails
                              </button>
                            </div>
                          <% end %>
                        </div>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            <% else %>
              <div class="text-center py-12">
                <.icon name="hero-envelope-open" class="w-16 h-16 mx-auto mb-4 text-base-content/30" />
                <h2 class="text-xl font-semibold text-base-content/70 mb-2">Email Not Found</h2>
                <p class="text-base-content/60 mb-4">
                  The email with ID {@email_id} could not be found.
                </p>
                <.link navigate={Routes.path("/admin/email-logs")} class="btn btn-primary">
                  Back to Email Logs
                </.link>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  ## --- Private Helper Functions ---

  # Load email data and related information
  defp load_email_data(socket) do
    email_id = socket.assigns.email_id

    try do
      email_log = EmailTracking.get_log!(email_id)
      events = EmailTracking.list_events_for_log(email_id)
      related_emails = get_related_emails(email_log)

      socket
      |> assign(:email_log, email_log)
      |> assign(:events, events)
      |> assign(:related_emails, related_emails)
      |> assign(:loading, false)
      |> assign(:show_headers, false)
      |> assign(:show_body, false)
      |> assign(:page_title, "Email ##{email_id}")
    rescue
      Ecto.NoResultsError ->
        socket
        |> assign(:email_log, nil)
        |> assign(:events, [])
        |> assign(:related_emails, [])
        |> assign(:loading, false)

      error ->
        Logger.error("Failed to load email data: #{inspect(error)}")

        socket
        |> assign(:loading, false)
        |> put_flash(:error, "Failed to load email data")
    end
  end

  # Get related emails (same campaign or template)
  defp get_related_emails(%EmailLog{
         campaign_id: campaign_id,
         template_name: template_name,
         id: current_id
       }) do
    filters = %{limit: 10}

    filters =
      cond do
        campaign_id -> Map.put(filters, :campaign_id, campaign_id)
        template_name -> Map.put(filters, :template_name, template_name)
        true -> filters
      end

    EmailTracking.list_logs(filters)
    |> Enum.reject(fn log -> log.id == current_id end)
  end

  defp get_related_emails(_), do: []

  # Helper functions for template
  defp status_badge_class(status, extra_classes \\ "badge-sm") do
    base_class = "badge #{extra_classes}"

    case status do
      "sent" -> "#{base_class} badge-info"
      "delivered" -> "#{base_class} badge-success"
      "bounced" -> "#{base_class} badge-error"
      "opened" -> "#{base_class} badge-primary"
      "clicked" -> "#{base_class} badge-secondary"
      "failed" -> "#{base_class} badge-error"
      _ -> "#{base_class} badge-ghost"
    end
  end

  defp event_marker_class(event_type) do
    base_class = "w-6 h-6 rounded-full flex items-center justify-center text-white"

    case event_type do
      "send" -> "#{base_class} bg-blue-500"
      "delivery" -> "#{base_class} bg-green-500"
      "bounce" -> "#{base_class} bg-red-500"
      "complaint" -> "#{base_class} bg-orange-500"
      "open" -> "#{base_class} bg-purple-500"
      "click" -> "#{base_class} bg-indigo-500"
      _ -> "#{base_class} bg-base-content"
    end
  end

  defp event_icon(event_type) do
    case event_type do
      "send" -> "hero-paper-airplane"
      "delivery" -> "hero-check-circle"
      "bounce" -> "hero-exclamation-triangle"
      "complaint" -> "hero-flag"
      "open" -> "hero-eye"
      "click" -> "hero-cursor-arrow-rays"
      _ -> "hero-clock"
    end
  end

  defp format_event_title(event_type) do
    case event_type do
      "send" -> "Email Sent"
      "delivery" -> "Email Delivered"
      "bounce" -> "Email Bounced"
      "complaint" -> "Spam Complaint"
      "open" -> "Email Opened"
      "click" -> "Link Clicked"
      _ -> String.capitalize(event_type)
    end
  end

  # Render event-specific details
  defp render_event_details(event) do
    case event.event_type do
      "bounce" ->
        assigns = %{event: event}

        ~H"""
        <div class="text-xs text-base-content/60">
          <div>Type: <span class="font-medium">{@event.bounce_type || "unknown"}</span></div>
          <%= if get_in(@event.event_data, ["reason"]) do %>
            <div>Reason: {get_in(@event.event_data, ["reason"])}</div>
          <% end %>
        </div>
        """

      "complaint" ->
        assigns = %{event: event}

        ~H"""
        <div class="text-xs text-base-content/60">
          <div>Type: <span class="font-medium">{@event.complaint_type || "abuse"}</span></div>
          <%= if get_in(@event.event_data, ["feedback_id"]) do %>
            <div>Feedback ID: {get_in(@event.event_data, ["feedback_id"])}</div>
          <% end %>
        </div>
        """

      "open" ->
        assigns = %{event: event}

        ~H"""
        <div class="text-xs text-base-content/60">
          <%= if @event.ip_address do %>
            <div>IP: <span class="font-mono">{@event.ip_address}</span></div>
          <% end %>
          <%= if get_in(@event.geo_location, ["country"]) do %>
            <div>Location: {get_in(@event.geo_location, ["country"])}</div>
          <% end %>
        </div>
        """

      "click" ->
        assigns = %{event: event}

        ~H"""
        <div class="text-xs text-base-content/60">
          <%= if @event.link_url do %>
            <div class="mb-1">
              Link:
              <a href={@event.link_url} target="_blank" class="text-blue-600 hover:underline break-all">
                {String.slice(@event.link_url, 0, 50)}{if String.length(@event.link_url) > 50, do: "..."}
              </a>
            </div>
          <% end %>
          <%= if @event.ip_address do %>
            <div>IP: <span class="font-mono">{@event.ip_address}</span></div>
          <% end %>
        </div>
        """

      _ ->
        assigns = %{event: event}

        ~H"""
        <%= if map_size(@event.event_data) > 0 do %>
          <div class="text-xs text-gray-600">
            Additional data available
          </div>
        <% end %>
        """
    end
  end

  defp format_bytes(nil), do: "Unknown"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} bytes"
    end
  end

  defp format_duration(start_time, end_time) do
    diff_seconds = DateTime.diff(end_time, start_time, :second)

    cond do
      diff_seconds < 60 -> "#{diff_seconds}s"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m #{rem(diff_seconds, 60)}s"
      true -> "#{div(diff_seconds, 3600)}h #{div(rem(diff_seconds, 3600), 60)}m"
    end
  end

  defp get_current_path(_socket, _session, email_id) do
    # For EmailDetailsLive, return email details path with ID
    Routes.path("/admin/email-logs/#{email_id}")
  end
end
