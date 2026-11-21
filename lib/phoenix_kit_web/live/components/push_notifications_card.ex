defmodule PhoenixKitWeb.Live.Components.PushNotificationsCard do
  @moduledoc """
  "Browser" card of a user's notification settings: turn push notifications
  on in this browser, see the devices that have them, remove one
  (`PhoenixKit.Notifications.Push`). Shown while the site offers push
  (`push_enabled`).

  The `PkPush` hook (admin bundle) does the browser's part: it registers the
  service worker as the card mounts — so the permission prompt, which a
  browser shows only during a click, is not delayed by it — reports the
  browser's state (`push_state`: unsupported, needs installing on an iPhone,
  not asked, allowed, blocked; and this browser's endpoint, to mark "this
  device"), and on **Turn on** asks the browser and sends the subscription
  (`push_subscribe`). It also keeps the browser's own id in a cookie
  (`pk_push_browser`), so a logout in this browser stops its pushes.

  Refused on the server, like the Telegram card: turning push on in a
  **borrowed session** (`impersonated` must be exactly `false`), and for a
  managed organization or a service user. Removing a device stays possible
  in a borrowed session, like revoking a key.

  The first time push is turned on, the types the account gets by email are
  ticked for "Browser" too (Max, 2026-11-21); the table above shows them to
  change.

  Attrs: `id`, `user` (the signed-in `%User{}`), `impersonated` (boolean).
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Notifications.Push
  alias PhoenixKit.Notifications.Push.WebPush
  alias PhoenixKit.Utils.Routes

  @states ~w(unknown unsupported ios_install default granted denied)

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:browser_state, fn -> "unknown" end)
      |> assign_new(:this_hash, fn -> nil end)
      |> assign_new(:message, fn -> nil end)
      |> assign(:enabled, Push.enabled?())
      |> load_devices()

    {:ok, socket}
  end

  defp load_devices(socket) do
    assign(socket, :devices, Push.devices(socket.assigns.user.uuid))
  rescue
    _ -> assign(socket, :devices, [])
  end

  defp allowed?(%{impersonated: false, user: user}),
    do: user.managed_by_members != true and Map.get(user, :api_only, false) != true

  defp allowed?(_assigns), do: false

  @impl true
  def handle_event("push_state", params, socket) do
    state = if params["state"] in @states, do: params["state"], else: "unknown"

    this =
      case params["endpoint"] do
        endpoint when is_binary(endpoint) and byte_size(endpoint) <= 2_048 -> Push.hash(endpoint)
        _ -> nil
      end

    {:noreply, assign(socket, browser_state: state, this_hash: this)}
  end

  def handle_event("push_subscribe", %{"subscription" => %{} = subscription} = params, socket) do
    if allowed?(socket.assigns) do
      opts = [
        impersonated: socket.assigns.impersonated,
        browser_id: params["browser_id"],
        label: params["label"]
      ]

      case Push.subscribe(socket.assigns.user, subscription, opts) do
        {:ok, installation} ->
          {:noreply,
           socket
           |> assign(
             browser_state: "granted",
             this_hash: installation.endpoint_hash,
             message: {:info, gettext("Notifications are on in this browser.")}
           )
           |> load_devices()}

        {:error, reason} ->
          {:noreply, assign(socket, :message, {:error, error_text(reason)})}
      end
    else
      {:noreply,
       assign(socket, :message, {:error, gettext("Notifications can't be turned on here.")})}
    end
  end

  def handle_event("push_subscribe", _params, socket), do: {:noreply, socket}

  def handle_event("push_remove", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    here? =
      Enum.any?(
        socket.assigns.devices,
        &(to_string(&1.uuid) == uuid and &1.endpoint_hash == socket.assigns.this_hash)
      )

    :ok = Push.remove_device(socket.assigns.user.uuid, uuid)

    socket =
      socket
      |> load_devices()
      |> assign(:message, {:info, gettext("Removed.")})

    # The browser forgets its subscription too, when it was this one.
    socket = if here?, do: push_event(socket, "pk-push-unsubscribe", %{}), else: socket
    {:noreply, socket}
  end

  def handle_event("push_remove", _params, socket), do: {:noreply, socket}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp error_text(:impersonated),
    do: gettext("Notifications can't be turned on while you act as someone else.")

  defp error_text(:not_allowed), do: gettext("This account can't get browser notifications.")
  defp error_text(:too_many_devices), do: gettext("Remove a device first: the limit is reached.")

  defp error_text(:endpoint_refused),
    do: gettext("This browser's notification service isn't supported.")

  defp error_text(:not_enabled), do: gettext("Browser notifications are off on this site.")
  defp error_text(_), do: gettext("Notifications could not be turned on. Try again.")

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        key: if(assigns.enabled, do: WebPush.public_key_b64()),
        worker: Routes.path("/push/sw.js"),
        install: Routes.path("/push/install"),
        here_on?:
          assigns.this_hash != nil and
            Enum.any?(assigns.devices, &(&1.endpoint_hash == assigns.this_hash))
      )

    ~H"""
    <div>
      <section
        :if={@enabled}
        id={@id}
        phx-hook="PkPush"
        phx-target={@myself}
        data-key={@key}
        data-worker={@worker}
        class="card bg-base-200/40 mt-4"
      >
        <div class="card-body p-4 gap-3">
          <h3 class="font-semibold flex items-center gap-2">
            <.icon name="hero-computer-desktop" class="w-5 h-5 text-primary" />
            {gettext("Browser")}
          </h3>
          <p class="text-sm text-base-content/70">
            {gettext(
              "Notifications on this computer or phone, even when the site isn't open. Choose which ones in the Browser column above."
            )}
          </p>

          <div
            :if={@message}
            class={[
              "alert text-sm",
              elem(@message, 0) == :error && "alert-error",
              elem(@message, 0) == :info && "alert-success"
            ]}
          >
            {elem(@message, 1)}
          </div>

          <%= cond do %>
            <% @browser_state == "unsupported" -> %>
              <p class="text-sm">{gettext("This browser can't show notifications from websites.")}</p>
            <% @browser_state == "ios_install" -> %>
              <p class="text-sm">
                {gettext("On iPhone and iPad, add the site to your Home Screen first.")}
                <a href={@install} class="link link-primary">{gettext("How to")}</a>
              </p>
            <% @browser_state == "denied" -> %>
              <p class="text-sm">
                {gettext(
                  "Notifications are blocked for this site in this browser. Allow them in the browser's site settings, then reload this page."
                )}
              </p>
            <% @here_on? -> %>
              <p class="text-sm text-success flex items-center gap-1">
                <.icon name="hero-check-circle" class="w-4 h-4" /> {gettext("On in this browser.")}
              </p>
            <% not allowed?(assigns) -> %>
              <p class="text-sm text-base-content/70">
                {gettext("Notifications can't be turned on here.")}
              </p>
            <% true -> %>
              <div>
                <button type="button" data-push-enable class="btn btn-primary btn-sm">
                  {gettext("Turn on in this browser")}
                </button>
              </div>
          <% end %>

          <div :if={@devices != []}>
            <p class="text-sm font-medium mb-1">{gettext("Devices")}</p>
            <ul class="flex flex-col gap-1">
              <li :for={device <- @devices} class="flex items-center gap-2 text-sm">
                <span class="flex-1 truncate">{device.label || gettext("A browser")}</span>
                <span :if={device.endpoint_hash == @this_hash} class="badge badge-sm badge-primary">
                  {gettext("This device")}
                </span>
                <button
                  type="button"
                  phx-click="push_remove"
                  phx-value-uuid={device.uuid}
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs"
                >
                  {gettext("Remove")}
                </button>
              </li>
            </ul>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
