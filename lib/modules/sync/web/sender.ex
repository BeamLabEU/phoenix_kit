defmodule PhoenixKit.Modules.Sync.Web.Sender do
  @moduledoc """
  Sender-side LiveView for DB Sync.

  This is the site that has data to share with another site.

  ## Flow

  1. Generate a connection code
  2. Share the code with the receiver (along with this site's URL)
  3. Wait for receiver to connect
  4. Serve data requests from the receiver
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Sync
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.Date, as: UtilsDate

  require Logger

  @impl true
  def mount(params, _session, socket) do
    locale = params["locale"] || "en"
    project_title = Settings.get_project_title()
    site_url = Settings.get_setting("site_url", "")

    socket =
      socket
      |> assign(:page_title, "Send Data")
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/sync/send", locale: locale))
      |> assign(:site_url, site_url)
      |> assign(:step, :generate_code)
      |> assign(:session, nil)
      # Multiple receivers support - map of pid => receiver_data
      |> assign(:receivers, %{})
      |> assign(:connection_status, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # Clean up session on unmount
    if socket.assigns.session do
      Sync.delete_session(socket.assigns.session.code)
    end

    :ok
  end

  # ===========================================
  # EVENT HANDLERS
  # ===========================================

  @impl true
  def handle_event("generate_code", _params, socket) do
    case Sync.create_session(:send) do
      {:ok, session} ->
        socket =
          socket
          |> assign(:session, session)
          |> assign(:step, :waiting_for_receiver)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to generate code: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("regenerate_code", _params, socket) do
    if socket.assigns.session do
      Sync.delete_session(socket.assigns.session.code)
    end

    case Sync.create_session(:send) do
      {:ok, session} ->
        socket =
          socket
          |> assign(:session, session)
          |> assign(:receivers, %{})

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to generate code: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    if socket.assigns.session do
      Sync.delete_session(socket.assigns.session.code)
    end

    socket =
      socket
      |> assign(:session, nil)
      |> assign(:step, :generate_code)
      |> assign(:receivers, %{})

    {:noreply, socket}
  end

  @impl true
  def handle_event("disconnect", _params, socket) do
    if socket.assigns.session do
      Sync.delete_session(socket.assigns.session.code)
    end

    socket =
      socket
      |> assign(:session, nil)
      |> assign(:step, :generate_code)
      |> assign(:receivers, %{})
      |> assign(:connection_status, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("disconnect_receiver", %{"pid" => pid_string}, socket) do
    # Find and remove the receiver by PID string
    pid = string_to_pid(pid_string)

    if pid && Map.has_key?(socket.assigns.receivers, pid) do
      # The channel will terminate when process exits, but we can also
      # remove it from our tracking immediately
      receivers = Map.delete(socket.assigns.receivers, pid)

      socket =
        socket
        |> assign(:receivers, receivers)
        |> maybe_update_step_for_receivers()

      {:noreply, put_flash(socket, :info, "Receiver disconnected")}
    else
      {:noreply, socket}
    end
  end

  # ===========================================
  # MESSAGE HANDLERS (from Channel)
  # ===========================================

  @impl true
  def handle_info({:sync, {:receiver_joined, channel_pid, full_info}}, socket) do
    Logger.info("Sync.Sender: Receiver connected - #{inspect(full_info)}")

    # Extract receiver_info and connection_info from the full_info map
    # Handle both new format (with :receiver_info/:connection_info keys) and old format
    {receiver_info, connection_info} =
      case full_info do
        %{receiver_info: ri, connection_info: ci} -> {ri, ci}
        info when is_map(info) -> {info, %{}}
      end

    # Add this receiver to our map
    receiver_data = %{
      receiver_info: receiver_info,
      connection_info: connection_info,
      connected_at: UtilsDate.utc_now()
    }

    receivers = Map.put(socket.assigns.receivers, channel_pid, receiver_data)

    socket =
      socket
      |> assign(:receivers, receivers)
      |> assign(:step, :connected)
      |> assign(:connection_status, nil)

    {:noreply, socket}
  end

  # Handle old message format (backwards compatibility)
  @impl true
  def handle_info({:sync, {:receiver_joined, channel_pid}}, socket) do
    Logger.info("Sync.Sender: Receiver connected (no info)")

    receiver_data = %{
      receiver_info: %{},
      connection_info: %{},
      connected_at: UtilsDate.utc_now()
    }

    receivers = Map.put(socket.assigns.receivers, channel_pid, receiver_data)

    socket =
      socket
      |> assign(:receivers, receivers)
      |> assign(:step, :connected)
      |> assign(:connection_status, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync, {:receiver_disconnected, channel_pid}}, socket) do
    Logger.info("Sync.Sender: Receiver disconnected - #{inspect(channel_pid)}")

    receivers = Map.delete(socket.assigns.receivers, channel_pid)

    socket =
      socket
      |> assign(:receivers, receivers)
      |> maybe_update_step_for_receivers()
      |> put_flash(:info, "A receiver disconnected")

    {:noreply, socket}
  end

  # Handle old message format (backwards compatibility) - removes all receivers
  @impl true
  def handle_info({:sync, :receiver_disconnected}, socket) do
    Logger.info("Sync.Sender: Receiver disconnected (old format)")

    # For old format, we don't know which receiver, so just flash a message
    # The channel terminate will send the new format with PID
    socket = put_flash(socket, :info, "A receiver disconnected")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync, msg}, socket) do
    Logger.debug("Sync.Sender: Received message - #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ===========================================
  # RENDER
  # ===========================================

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="{@project_title} - Send Data"
      current_path={@current_path}
      project_title={@project_title}
      current_locale={@current_locale}
    >
      <div class="container flex flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-8">
          <.link
            navigate={Routes.path("/admin/sync", locale: @current_locale)}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>

          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">Send Data</h1>
            <p class="text-lg text-base-content/70">
              Share your data with another site
            </p>
          </div>
        </header>

        <div class="max-w-2xl mx-auto w-full">
          <%= case @step do %>
            <% :generate_code -> %>
              <.render_generate_code_step {assigns} />
            <% :waiting_for_receiver -> %>
              <.render_waiting_step {assigns} />
            <% :connected -> %>
              <.render_connected_step {assigns} />
          <% end %>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp render_generate_code_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body items-center text-center">
        <div class="text-6xl mb-4">📤</div>
        <h2 class="card-title text-2xl mb-4">Ready to Send</h2>
        <p class="text-base-content/70 mb-6">
          Click the button below to generate a connection code. Share this code and your site URL
          with the site that wants to receive your data.
        </p>
        <button phx-click="generate_code" class="btn btn-primary btn-lg">
          <.icon name="hero-key" class="w-5 h-5" /> Generate Connection Code
        </button>
      </div>
    </div>
    """
  end

  defp render_waiting_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-2xl mb-4 justify-center">
          <.icon name="hero-signal" class="w-6 h-6 text-primary animate-pulse" />
          Waiting for Connection
        </h2>

        <%!-- Connection Code Display --%>
        <div class="bg-base-200 rounded-lg p-6 mb-6">
          <p class="text-sm text-base-content/70 mb-2 text-center">Connection Code</p>
          <div class="flex items-center justify-center gap-2">
            <code class="text-4xl font-mono font-bold tracking-widest text-primary">
              {@session.code}
            </code>
            <button
              id="copy-code-btn"
              onclick={"navigator.clipboard.writeText('#{@session.code}').then(() => { this.querySelector('.copy-icon').classList.add('hidden'); this.querySelector('.check-icon').classList.remove('hidden'); setTimeout(() => { this.querySelector('.copy-icon').classList.remove('hidden'); this.querySelector('.check-icon').classList.add('hidden'); }, 2000); })"}
              class="btn btn-ghost btn-sm"
              title="Copy to clipboard"
            >
              <.icon name="hero-clipboard" class="w-5 h-5 copy-icon" />
              <.icon name="hero-check" class="w-5 h-5 text-success check-icon hidden" />
            </button>
          </div>
        </div>

        <%!-- Site URL --%>
        <%= if @site_url != "" do %>
          <div class="bg-base-200 rounded-lg p-4 mb-6">
            <p class="text-sm text-base-content/70 mb-1 text-center">Your Site URL</p>
            <p class="text-center font-mono text-sm break-all">{@site_url}</p>
          </div>
        <% else %>
          <div class="alert alert-warning mb-6">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>
              Site URL not configured. Set it in
              <.link navigate={Routes.path("/admin/settings")} class="link">Settings</.link>
              for easier sharing.
            </span>
          </div>
        <% end %>

        <%!-- Instructions --%>
        <div class="bg-base-200 rounded-lg p-4 mb-6">
          <p class="font-semibold mb-2">Share with the receiver:</p>
          <ol class="list-decimal list-inside text-sm text-base-content/70 space-y-1">
            <li>Your site URL (above)</li>
            <li>The connection code</li>
          </ol>
          <p class="text-sm text-base-content/70 mt-2">
            The receiver will enter these on their "Receive Data" page to connect.
          </p>
        </div>

        <%!-- Session Notice --%>
        <div class="text-center text-sm text-base-content/50 mb-6">
          <.icon name="hero-signal" class="w-4 h-4 inline" /> Code is valid while this page stays open
        </div>

        <%!-- Actions --%>
        <div class="flex gap-4 justify-center">
          <button phx-click="regenerate_code" class="btn btn-outline btn-sm">
            <.icon name="hero-arrow-path" class="w-4 h-4" /> New Code
          </button>
          <button phx-click="cancel" class="btn btn-ghost btn-sm">
            Cancel
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp render_connected_step(assigns) do
    receiver_count = map_size(assigns.receivers)

    assigns = assign(assigns, :receiver_count, receiver_count)

    ~H"""
    <div class="space-y-6">
      <%!-- Connection Status Header --%>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <div class="text-center mb-4">
            <div class="text-6xl mb-4">✅</div>
            <h2 class="card-title text-2xl justify-center text-success">
              <%= if @receiver_count == 1 do %>
                Receiver Connected!
              <% else %>
                {@receiver_count} Receivers Connected!
              <% end %>
            </h2>
            <p class="text-base-content/70">
              <%= if @receiver_count == 1 do %>
                A receiver is connected and can browse your data.
              <% else %>
                Multiple receivers are connected and can browse your data.
              <% end %>
            </p>
          </div>

          <div class="bg-base-200 rounded-lg p-4 mb-4">
            <p class="text-sm text-base-content/70 mb-1 text-center">Session Code</p>
            <p class="text-center font-mono font-bold tracking-widest text-xl">{@session.code}</p>
          </div>

          <%= if @connection_status do %>
            <div class="alert alert-info">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              <span>{@connection_status}</span>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Connected Receivers --%>
      <%= for {pid, receiver_data} <- @receivers do %>
        <.render_receiver_card
          pid={pid}
          receiver_data={receiver_data}
          show_disconnect={@receiver_count > 0}
        />
      <% end %>

      <%!-- Session Info --%>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <div class="alert alert-warning">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <div>
              <p class="font-semibold">Keep this page open!</p>
              <p class="text-sm">
                Your data is being served to receivers while this page remains open.
                Closing this page will disconnect all transfer sessions.
              </p>
            </div>
          </div>

          <div class="flex justify-center mt-4">
            <button phx-click="disconnect" class="btn btn-outline btn-error">
              <.icon name="hero-x-mark" class="w-5 h-5" /> End All Sessions
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :pid, :any, required: true
  attr :receiver_data, :map, required: true
  attr :show_disconnect, :boolean, default: true

  defp render_receiver_card(assigns) do
    receiver_info = assigns.receiver_data.receiver_info || %{}
    connection_info = assigns.receiver_data.connection_info || %{}

    assigns =
      assigns
      |> assign(:receiver_info, receiver_info)
      |> assign(:connection_info, connection_info)

    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <%!-- Header with receiver identity --%>
        <div class="flex items-start justify-between">
          <div>
            <h3 class="card-title text-lg">
              <.icon name="hero-user-circle" class="w-5 h-5 text-primary" />
              <%= if @receiver_info["user_name"] || @receiver_info["user_email"] do %>
                {@receiver_info["user_name"] || @receiver_info["user_email"]}
              <% else %>
                Anonymous Receiver
              <% end %>
            </h3>
            <%= if @receiver_info["project_title"] do %>
              <p class="text-sm text-base-content/70">
                from <span class="font-semibold">{@receiver_info["project_title"]}</span>
              </p>
            <% end %>
          </div>
          <%= if @show_disconnect do %>
            <button
              phx-click="disconnect_receiver"
              phx-value-pid={pid_to_string(@pid)}
              class="btn btn-ghost btn-sm text-error"
              title="Disconnect this receiver"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          <% end %>
        </div>

        <%!-- Connection details grid --%>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-3 mt-4">
          <%= if @receiver_info["site_url"] do %>
            <.info_field
              label="Site URL"
              value={@receiver_info["site_url"]}
              icon="hero-globe-alt"
              mono
            />
          <% end %>
          <%= if @connection_info[:remote_ip] do %>
            <.info_field label="Remote IP" value={@connection_info[:remote_ip]} icon="hero-map-pin" />
          <% end %>
          <.info_field
            label="Connected"
            value={format_datetime(@receiver_data.connected_at)}
            icon="hero-clock"
          />
          <%= if @connection_info[:origin] do %>
            <.info_field
              label="Origin"
              value={@connection_info[:origin]}
              icon="hero-arrow-top-right-on-square"
              mono
            />
          <% end %>
        </div>

        <%!-- Expandable details --%>
        <%= if map_size(@connection_info) > 2 do %>
          <details class="mt-3">
            <summary class="text-xs text-base-content/60 cursor-pointer hover:text-base-content">
              More connection details...
            </summary>
            <div class="grid grid-cols-2 md:grid-cols-3 gap-3 mt-3 pt-3 border-t border-base-300">
              <%= if @connection_info[:host] do %>
                <.info_field
                  label="Host"
                  value={format_host(@connection_info)}
                  icon="hero-server"
                  mono
                />
              <% end %>
              <%= if @connection_info[:referer] do %>
                <.info_field label="Referer" value={@connection_info[:referer]} icon="hero-link" mono />
              <% end %>
              <%= if @connection_info[:websocket_version] do %>
                <.info_field
                  label="WS Version"
                  value={@connection_info[:websocket_version]}
                  icon="hero-bolt"
                />
              <% end %>
              <%= if @connection_info[:accept_language] do %>
                <.info_field
                  label="Language"
                  value={@connection_info[:accept_language]}
                  icon="hero-language"
                />
              <% end %>
            </div>
            <%= if @connection_info[:user_agent] do %>
              <div class="mt-3">
                <p class="text-xs text-base-content/60 mb-1">User Agent</p>
                <p class="text-xs font-mono text-base-content/70 break-all bg-base-200 p-2 rounded">
                  {@connection_info[:user_agent]}
                </p>
              </div>
            <% end %>
          </details>
        <% end %>
      </div>
    </div>
    """
  end

  # Component for displaying an info field
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :icon, :string, default: nil
  attr :mono, :boolean, default: false

  defp info_field(assigns) do
    ~H"""
    <div>
      <p class="text-xs text-base-content/60 mb-1 flex items-center gap-1">
        <%= if @icon do %>
          <.icon name={@icon} class="w-3 h-3" />
        <% end %>
        {@label}
      </p>
      <%= if @value do %>
        <p class={["text-sm", @mono && "font-mono text-xs break-all"]}>
          {@value}
        </p>
      <% else %>
        <p class="text-sm text-base-content/40 italic">Not provided</p>
      <% end %>
    </div>
    """
  end

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_datetime(_), do: nil

  defp format_host(%{scheme: scheme, host: host, port: port}) when not is_nil(host) do
    "#{scheme}://#{host}:#{port}"
  end

  defp format_host(_), do: nil

  # Helper to update step when receivers change
  defp maybe_update_step_for_receivers(socket) do
    if map_size(socket.assigns.receivers) == 0 do
      assign(socket, :step, :waiting_for_receiver)
    else
      socket
    end
  end

  # Convert PID string back to PID (for disconnect button)
  defp string_to_pid(pid_string) when is_binary(pid_string) do
    # PID string looks like "#PID<0.123.0>" - extract the numbers
    case Regex.run(~r/<(.+)>/, pid_string) do
      [_, pid_part] -> :erlang.list_to_pid(~c"<#{pid_part}>")
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp string_to_pid(_), do: nil

  # Convert PID to string for use in HTML attributes
  defp pid_to_string(pid) when is_pid(pid), do: inspect(pid)
  defp pid_to_string(_), do: ""
end
