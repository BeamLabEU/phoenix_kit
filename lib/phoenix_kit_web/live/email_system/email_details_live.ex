defmodule PhoenixKitWeb.Live.EmailSystem.EmailDetailsLive do
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

  This LiveView is mounted at `{prefix}/admin/emails/:id` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

      # In your Phoenix router
      live "/email-logs/:id", PhoenixKitWeb.Live.EmailSystem.EmailDetailsLive, :show

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.EmailSystem
  alias PhoenixKit.EmailSystem.EmailLog
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Check if email is enabled
    if EmailSystem.enabled?() do
      case Integer.parse(id) do
        {email_id, _} ->
          # Get project title from settings
          project_title = Settings.get_setting("project_title", "PhoenixKit")

          socket =
            socket
            |> assign(:email_id, email_id)
            |> assign(:project_title, project_title)
            |> assign(:email_log, nil)
            |> assign(:events, [])
            |> assign(:related_emails, [])
            |> assign(:loading, true)
            |> assign(:syncing, false)
            |> load_email_data()

          {:ok, socket}

        _ ->
          {:ok,
           socket
           |> put_flash(:error, "Invalid email ID")
           |> push_navigate(to: Routes.path("/admin/emails"))}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Email is not enabled")
       |> push_navigate(to: Routes.path("/admin/emails"))}
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
  def handle_event("sync_status", _params, socket) do
    if socket.assigns.email_log do
      # Determine which message ID to use for sync (prefer AWS message ID)
      {message_id, id_type} =
        if socket.assigns.email_log.aws_message_id do
          {socket.assigns.email_log.aws_message_id, "AWS SES message ID"}
        else
          {socket.assigns.email_log.message_id, "internal message ID"}
        end

      socket = assign(socket, :syncing, true)

      case EmailSystem.sync_email_status(message_id) do
        {:ok, result} ->
          flash_message = build_sync_flash_message(result, id_type)
          flash_type = determine_flash_type(result)

          socket =
            socket
            |> assign(:syncing, false)
            |> put_flash(flash_type, flash_message)
            |> load_email_data()

          {:noreply, socket}

        {:error, reason} ->
          flash_message = build_error_flash_message(reason, message_id, socket, id_type)

          socket =
            socket
            |> assign(:syncing, false)
            |> put_flash(:error, flash_message)

          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "❌ Email log not found")}
    end
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
  def handle_event("view_related", %{"campaign_id" => campaign_id}, socket) do
    {:noreply,
     socket
     |> push_navigate(to: Routes.path("/admin/emails?campaign_id=#{campaign_id}"))}
  end

  @impl true
  def handle_event("view_related", %{"template_name" => template_name}, socket) do
    {:noreply,
     socket
     |> push_navigate(to: Routes.path("/admin/emails?template_name=#{template_name}"))}
  end

  ## --- Template ---

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={"Email #{@email_id}"}
      current_path={@url_path}
      project_title={@project_title}
    >
      <div class="container flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <%!-- Back Button (Left aligned) --%>
          <.link
            navigate={Routes.path("/admin/emails")}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0 -mb-12"
          >
            <.icon_arrow_left /> Back to Emails
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
                  <.link
                    href={Routes.path("/admin/emails/#{@email_id}/export")}
                    target="_blank"
                    class="btn btn-outline btn-sm"
                  >
                    <.icon name="hero-arrow-down-tray" class="w-4 h-4 mr-1" /> Export CSV
                  </.link>

                  <button
                    phx-click="sync_status"
                    class="btn btn-outline btn-sm"
                    disabled={assigns[:syncing]}
                  >
                    <%= if assigns[:syncing] do %>
                      <span class="loading loading-spinner loading-xs mr-1"></span> Syncing...
                    <% else %>
                      <.icon name="hero-arrow-path-rounded-square" class="w-4 h-4 mr-1" /> Sync Status
                    <% end %>
                  </button>

                  <button
                    phx-click="refresh"
                    class="btn btn-outline btn-sm"
                    disabled={assigns[:loading]}
                  >
                    <%= if assigns[:loading] do %>
                      <span class="loading loading-spinner loading-xs mr-1"></span> Loading...
                    <% else %>
                      <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" /> Refresh
                    <% end %>
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

                      <%!-- Message IDs Section --%>
                      <div class="border-t pt-4 mt-4 space-y-3">
                        <div>
                          <label class="text-sm font-medium text-base-content/70">
                            Message ID (Internal)
                          </label>
                          <p class="text-xs font-mono text-base-content/90 break-all">
                            {@email_log.message_id}
                          </p>
                        </div>

                        <%= if @email_log.aws_message_id do %>
                          <div>
                            <label class="text-sm font-medium text-base-content/70">
                              AWS Message ID
                            </label>
                            <p class="text-xs font-mono text-base-content/90 break-all">
                              {@email_log.aws_message_id}
                            </p>
                          </div>
                        <% end %>
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

                        <%= if @email_log.aws_message_id do %>
                          <div class="stat px-0 py-2">
                            <div class="stat-title text-xs">AWS Message ID</div>
                            <div class="stat-value text-xs font-mono break-all">
                              {@email_log.aws_message_id}
                            </div>
                          </div>
                        <% end %>

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
                              navigate={Routes.path("/admin/emails/email/#{related.id}")}
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
                <.link navigate={Routes.path("/admin/emails")} class="btn btn-primary">
                  Back to Emails
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
      email_log = EmailSystem.get_log!(email_id)
      events = EmailSystem.list_events_for_log(email_id)
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

    EmailSystem.list_logs(filters)
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

  # Build event details list for success message
  defp build_event_details(sqs_events, dlq_events, events_failed) do
    details = []

    details =
      if sqs_events > 0, do: ["#{sqs_events} from SQS" | details], else: details

    details =
      if dlq_events > 0, do: ["#{dlq_events} from DLQ" | details], else: details

    if events_failed > 0, do: ["#{events_failed} failed" | details], else: details
  end

  # Build success flash message
  defp build_sync_flash_message(result, id_type) do
    events_processed = Map.get(result, :events_processed, 0)
    total_events_found = Map.get(result, :total_events_found, 0)
    sqs_events = Map.get(result, :sqs_events_found, 0)
    dlq_events = Map.get(result, :dlq_events_found, 0)
    events_failed = Map.get(result, :events_failed, 0)
    existing_log_found = Map.get(result, :existing_log_found, false)
    log_updated = Map.get(result, :log_updated, false)
    message = Map.get(result, :message, nil)

    cond do
      total_events_found > 0 and events_processed > 0 ->
        details = build_event_details(sqs_events, dlq_events, events_failed)
        source_info = if length(details) > 0, do: " (#{Enum.join(details, ", ")})", else: ""
        status_info = if log_updated, do: " - Email status updated", else: ""

        "✅ Processed #{events_processed}/#{total_events_found} events#{source_info}#{status_info} using #{id_type}"

      total_events_found > 0 and events_processed == 0 ->
        "⚠️ Found #{total_events_found} events but none could be processed successfully using #{id_type}"

      not existing_log_found ->
        "ℹ️ No email log found in database for #{id_type}. Events may be for a different email."

      true ->
        search_info = " (searched using #{id_type})"
        (message || "No new events found in SQS or DLQ queues") <> search_info
    end
  end

  # Determine flash type based on sync results
  defp determine_flash_type(result) do
    events_processed = Map.get(result, :events_processed, 0)
    total_events_found = Map.get(result, :total_events_found, 0)
    existing_log_found = Map.get(result, :existing_log_found, false)

    cond do
      events_processed > 0 -> :info
      total_events_found > 0 and events_processed == 0 -> :warning
      not existing_log_found -> :warning
      true -> :info
    end
  end

  # Build ID info string for error messages
  defp build_id_info(message_id, email_log, id_type) do
    if message_id == email_log.message_id do
      " (using #{id_type})"
    else
      " (using #{id_type}: #{String.slice(message_id, 0, 20)}...)"
    end
  end

  # Build error flash message
  defp build_error_flash_message(reason, message_id, socket, id_type) do
    case reason do
      "AWS credentials not configured. Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables." ->
        "❌ AWS credentials not configured. Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables."

      "Email is disabled. Please enable it in settings." ->
        "❌ Email is disabled. Please enable it in admin settings."

      reason ->
        id_info = build_id_info(message_id, socket.assigns.email_log, id_type)
        "❌ Sync failed: #{reason}#{id_info}"
    end
  end
end
