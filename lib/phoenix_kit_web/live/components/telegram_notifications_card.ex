defmodule PhoenixKitWeb.Live.Components.TelegramNotificationsCard do
  @moduledoc """
  "Telegram" card of a user's notification settings: link a chat to the
  website's Telegram bot with one tap, choose what goes there, disconnect.

  Shown while the admin has chosen a website bot
  (`PhoenixKit.Integrations.Telegram.SiteBot`), or while the user still has a
  link to show; otherwise it renders nothing. It needs no permission beyond the
  settings page itself — an ordinary customer links their chat here, without
  the admin area or the `integrations` permission.

  **Connect** mints a one-time `https://t.me/<bot>?start=<token>` link
  (`Telegram.Linking`). The page then reads the bot's updates every few
  seconds while it stays open; the **I've sent it** button reads them at once.
  A user who closes the page after pressing Start is linked the next time
  they, or anyone, poll that bot — and the page checks once when it opens
  while a link is still pending. Nothing asks Telegram unless a link is
  pending, one timer per card drives the polling, and **Connect** / **I've sent
  it** are throttled, so clicking them quickly cannot pile up requests.

  A link Telegram's delivery has switched off (the user blocked the bot) shows
  as such, with a **Reconnect** button that runs the same one-tap flow. A link
  that runs out before Start is pressed says so.

  A link is a standing credential — a linked chat can read through the Machine API as the
  user (`PhoenixKit.API.Executor`) — so the card refuses to make one where a session must
  not hand out a credential:

    * in a **borrowed session** (an administrator impersonating the user): the host passes
      `impersonated`, a boolean computed with
      `PhoenixKitWeb.Users.MultiSession.impersonated?/1` in the mount of the page, never a
      constant. Anything but `false` (including no value) is refused, as in
      `PhoenixKitWeb.Live.Components.PersonalApiKeys`; the buttons are replaced by a note
      and the `connect` event is refused on the server;
    * for a **managed organization** (`managed_by_members`) or a service user: the card
      is not shown and every event is refused.

  A host that does not pass `impersonated` gets a note of its own ("can't be connected on
  this page"), not the one about the session. A managed organization or service user that
  still holds a link stored earlier is shown that and a **Disconnect** button only: the link
  is inert, so it is the account's to remove, not something to keep hidden.

  Disconnecting stays possible in a borrowed session, like revoking a key.

  When the link was dropped by account recovery (`Linking.drop_links/1`), the card says it
  was disconnected and has to be connected again.

  Attrs: `id`, `user` (the signed-in `%User{}`), `impersonated` (boolean, see above).
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Telegram.Linking
  alias PhoenixKit.Integrations.Telegram.SiteBot
  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.Users.Auth

  @poll_every_ms 3_000
  # Least time between two Connect / "I've sent it" clicks that reach Telegram.
  @min_interval_ms 2_000
  @channel "telegram"

  @impl true
  def update(%{poll: true}, socket) do
    socket = assign(socket, :poll_timer, nil)
    {:ok, if(socket.assigns.waiting, do: poll(socket), else: socket)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:link, fn -> nil end)
      |> assign_new(:message, fn -> nil end)
      |> assign_new(:polling, fn -> false end)
      |> assign_new(:opened, fn -> false end)
      |> assign_new(:poll_timer, fn -> nil end)
      |> assign_new(:last_call_at, fn -> nil end)
      |> assign_new(:waiting, fn -> false end)
      |> assign_new(:active, fn -> false end)
      |> refresh()

    # A link minted earlier may be waiting on a Start pressed after the page
    # was closed: look once on opening.
    socket =
      if not socket.assigns.opened and socket.assigns.waiting and not socket.assigns.polling do
        socket |> assign(:opened, true) |> poll()
      else
        assign(socket, :opened, true)
      end

    {:ok, socket}
  end

  # What the card shows, from the database: the bot, the user's link, and
  # whether a link they minted is still waiting for Start.
  defp refresh(socket) do
    was_waiting? = socket.assigns.waiting or socket.assigns.link != nil
    user = Auth.get_user!(socket.assigns.user.uuid)
    connection = SiteBot.connection_uuid()
    linked = Linking.linked(user)
    config = ChannelConfig.for_channel(user, @channel)

    # A link to a bot that is no longer the site's is not a link any more.
    linked = if linked && linked.connection_uuid == connection, do: linked, else: nil

    # Delivery switched the chat off (the user blocked the bot): linked, but
    # nothing arrives until they connect again.
    disabled? = linked != nil and config["status"] == "disabled"
    active = linked != nil and not disabled?

    waiting =
      connection != nil and (linked == nil or disabled?) and Linking.pending?(user, connection)

    socket
    |> assign(:fresh_user, user)
    |> assign(:refusal, refusal(user, socket.assigns[:impersonated]))
    |> assign(:link_dropped?, linked == nil and is_binary(config["link_dropped_at"]))
    |> assign(:connection, connection)
    |> assign(:linked, linked)
    |> assign(:disabled?, disabled?)
    |> assign(:config, config)
    |> assign(:waiting, waiting)
    |> assign(:active, active)
    |> assign(:own_bot?, own_bot?(user))
    |> note_expiry(was_waiting?, waiting, active)
  end

  # Who may not link a chat from here. Fails closed: `impersonated` must be `false`.
  defp refusal(user, impersonated) do
    cond do
      not Linking.linkable?(user) -> :managed
      impersonated == true -> :borrowed
      impersonated != false -> :unspecified
      true -> nil
    end
  end

  # A link that was waiting (or on screen) and is neither used nor still alive
  # has run out: say so instead of leaving a card that waits for nothing.
  defp note_expiry(socket, was_waiting?, waiting, active) do
    if was_waiting? and not waiting and not active and socket.assigns.connection != nil do
      socket
      |> assign(:link, nil)
      |> assign(
        :message,
        {:error, gettext("The link expired before Start was pressed. Get a new one.")}
      )
    else
      socket
    end
  end

  defp own_bot?(user) do
    "telegram"
    |> Integrations.list_connections(owner: {:user, user.uuid})
    |> Enum.any?(fn %{data: data} -> (data["chat_ids"] || []) != [] end)
  rescue
    _ -> false
  end

  # --- Events ---------------------------------------------------------------

  @impl true
  def handle_event(event, _params, %{assigns: %{refusal: :managed}} = socket)
      when event != "disconnect",
      do: {:noreply, socket}

  def handle_event("connect", _params, %{assigns: %{refusal: refusal}} = socket)
      when refusal in [:borrowed, :unspecified] do
    {:noreply, assign(socket, :message, {:error, refusal_message(refusal)})}
  end

  def handle_event("connect", _params, socket) do
    if throttled?(socket) do
      {:noreply, socket}
    else
      socket = touch(socket)
      %{fresh_user: user, connection: connection} = socket.assigns

      # The bot's name first: a failed getMe must not cost the user the link
      # they already have.
      with true <- connection != nil,
           name when is_binary(name) <- SiteBot.bot_username(connection),
           {:ok, token} <- Linking.create_token(user, connection) do
        {:noreply,
         socket
         |> assign(:link, Linking.deep_link(name, token))
         |> assign(:message, nil)
         |> refresh()
         |> schedule_poll()}
      else
        _ ->
          {:noreply,
           assign(
             socket,
             :message,
             {:error, gettext("Telegram is not available right now. Please try again later.")}
           )}
      end
    end
  end

  def handle_event("check", _params, socket) do
    if throttled?(socket), do: {:noreply, socket}, else: {:noreply, socket |> touch() |> poll()}
  end

  def handle_event("disconnect", _params, socket) do
    case Linking.unlink(socket.assigns.fresh_user) do
      :ok ->
        {:noreply,
         socket
         |> assign(:link, nil)
         |> assign(:message, {:info, gettext("Telegram disconnected.")})
         |> refresh()}

      {:error, _} ->
        {:noreply,
         assign(
           socket,
           :message,
           {:error, gettext("Telegram is not available right now. Please try again later.")}
         )}
    end
  end

  def handle_event("save_types", params, socket) do
    submitted = params["telegram_types"] || %{}
    keys = all_type_keys()
    types = Map.new(keys, &{&1, submitted[&1] == "true"})

    # Read again: the user held in the assigns may predate a link made since,
    # and the write would put the old channel config back.
    user = Auth.get_user!(socket.assigns.user.uuid)

    case ChannelConfig.update(user, @channel, &Map.put(&1, "types", types)) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(:message, {:info, gettext("Telegram preferences saved.")}) |> refresh()}

      {:error, _} ->
        {:noreply,
         assign(socket, :message, {:error, gettext("Could not save your Telegram preferences.")})}
    end
  end

  defp disconnect_confirm,
    do:
      gettext(
        "Disconnect this Telegram chat? Notifications stop, and it can no longer read your data."
      )

  defp refusal_message(:borrowed), do: gettext("Telegram can't be connected from this session.")
  defp refusal_message(:unspecified), do: gettext("Telegram can't be connected on this page.")

  defp throttled?(%{assigns: %{last_call_at: nil}}), do: false

  defp throttled?(%{assigns: %{last_call_at: at}}),
    do: System.monotonic_time(:millisecond) - at < min_interval_ms()

  # Overridable so a test can click twice without waiting out the interval.
  defp min_interval_ms,
    do: Application.get_env(:phoenix_kit, :telegram_card_min_interval_ms, @min_interval_ms)

  defp touch(socket), do: assign(socket, :last_call_at, System.monotonic_time(:millisecond))

  # --- Polling --------------------------------------------------------------

  # Only a card with a link pending asks Telegram anything.
  defp poll(%{assigns: %{polling: true}} = socket), do: socket

  defp poll(%{assigns: %{connection: connection, waiting: true}} = socket)
       when is_binary(connection) do
    socket
    |> assign(:polling, true)
    |> start_async(:poll, fn -> Linking.poll(connection) end)
  end

  defp poll(socket), do: socket

  @impl true
  def handle_async(:poll, result, socket) do
    was_active? = socket.assigns.active
    socket = socket |> assign(:polling, false) |> refresh()

    socket =
      cond do
        socket.assigns.active and not was_active? ->
          socket
          |> assign(:link, nil)
          |> assign(:message, {:info, gettext("Telegram connected.")})

        match?({:ok, {:error, _}}, result) ->
          assign(
            socket,
            :message,
            {:error, gettext("Could not reach Telegram just now — try again.")}
          )

        true ->
          socket
      end

    {:noreply, if(socket.assigns.waiting, do: schedule_poll(socket), else: socket)}
  end

  # One timer per card: a new one replaces the old, so quick clicks cannot
  # leave several polling chains running side by side.
  defp schedule_poll(socket) do
    if ref = socket.assigns.poll_timer, do: Process.cancel_timer(ref)

    ref = send_update_after(__MODULE__, [id: socket.assigns.id, poll: true], @poll_every_ms)
    assign(socket, :poll_timer, ref)
  end

  # --- Render ---------------------------------------------------------------

  defp all_type_keys do
    Enum.flat_map(Types.list(), fn type -> [type.key | Enum.map(type.sub_types, & &1.key)] end)
  end

  defp type_on?(config, key), do: ChannelConfig.type_enabled?(config, key)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={(@connection != nil and @refusal != :managed) or @linked != nil}
        class="mt-6 rounded-box border border-base-300 p-4 space-y-3"
      >
        <h3 class="font-semibold flex items-center gap-2">
          <.icon name="hero-paper-airplane" class="w-4 h-4 text-primary" /> {gettext("Telegram")}
        </h3>

        <div
          :if={@message}
          class={[
            "alert text-sm",
            elem(@message, 0) == :error && "alert-error",
            elem(@message, 0) == :info && "alert-success"
          ]}
        >
          <span>{elem(@message, 1)}</span>
        </div>

        <p :if={@own_bot?} class="text-xs text-base-content/60">
          {gettext(
            "You also have your own Telegram bot linked in your integrations — it is used first."
          )}
        </p>

        <%= cond do %>
          <% @linked && @refusal == :managed -> %>
            <div class="flex items-center justify-between gap-3">
              <span class="text-sm">
                {gettext(
                  "A Telegram chat connected to this account earlier is still linked. This account can no longer use Telegram."
                )}
              </span>
              <button
                type="button"
                phx-click="disconnect"
                phx-target={@myself}
                data-confirm={disconnect_confirm()}
                class="btn btn-ghost btn-xs text-error"
              >
                {gettext("Disconnect")}
              </button>
            </div>
          <% @linked && not (@disabled? and (@link != nil or @waiting)) -> %>
            <div class="flex items-center justify-between gap-3">
              <span :if={not @disabled?} class="text-sm">
                <span class="badge badge-success badge-sm mr-2">{gettext("Connected")}</span>
                {gettext(
                  "Notifications you pick below arrive in your Telegram chat, and this chat may read your data through the site's bot."
                )}
              </span>
              <span :if={@disabled?} class="text-sm">
                <span class="badge badge-warning badge-sm mr-2">{gettext("Switched off")}</span>
                {gettext(
                  "Telegram was switched off because delivery failed — for example, the bot was blocked."
                )}
              </span>
              <span class="flex items-center gap-1">
                <button
                  :if={@disabled? and @refusal == nil}
                  type="button"
                  phx-click="connect"
                  phx-target={@myself}
                  class="btn btn-primary btn-xs"
                >
                  {gettext("Reconnect")}
                </button>
                <button
                  type="button"
                  phx-click="disconnect"
                  phx-target={@myself}
                  data-confirm={disconnect_confirm()}
                  class="btn btn-ghost btn-xs text-error"
                >
                  {gettext("Disconnect")}
                </button>
              </span>
            </div>

            <form id={"#{@id}-types"} phx-submit="save_types" phx-target={@myself} class="space-y-2">
              <p class="text-xs text-base-content/60">
                {gettext("Nothing is sent to Telegram for a type you leave unchecked.")}
              </p>
              <%= for type <- Types.list() do %>
                <.checkbox
                  name={"telegram_types[#{type.key}]"}
                  checked={type_on?(@config, type.key)}
                  label={Types.translate(type, :label)}
                  class="checkbox-sm"
                />
                <div :if={type.sub_types != []} class="ml-8 space-y-1">
                  <.checkbox
                    :for={sub <- type.sub_types}
                    name={"telegram_types[#{sub.key}]"}
                    checked={type_on?(@config, sub.key)}
                    label={Types.translate(sub, :label)}
                    class="checkbox-xs"
                  />
                </div>
              <% end %>
              <div class="flex justify-end">
                <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
              </div>
            </form>
          <% @link -> %>
            <p class="text-sm">
              {gettext(
                "Open the link in Telegram and press Start. This page connects by itself within a few seconds."
              )}
            </p>
            <div class="flex flex-wrap items-center gap-2">
              <a href={@link} target="_blank" rel="noopener noreferrer" class="btn btn-primary btn-sm">
                <.icon name="hero-paper-airplane" class="w-4 h-4" /> {gettext("Open Telegram")}
              </a>
              <button
                type="button"
                phx-click="check"
                phx-target={@myself}
                class="btn btn-outline btn-sm"
                disabled={@polling}
              >
                {gettext("I've sent it")}
              </button>
            </div>
            <p class="text-xs text-base-content/60">
              {gettext("The link works once and expires in %{minutes} minutes.",
                minutes: Linking.ttl_minutes()
              )}
            </p>
          <% @waiting -> %>
            <p class="text-sm">
              {gettext(
                "Waiting for you to press Start in Telegram. If you already did, press the button; otherwise get a new link."
              )}
            </p>
            <div class="flex flex-wrap items-center gap-2">
              <button
                type="button"
                phx-click="check"
                phx-target={@myself}
                class="btn btn-outline btn-sm"
                disabled={@polling}
              >
                {gettext("I've sent it")}
              </button>
              <button
                :if={@refusal == nil}
                type="button"
                phx-click="connect"
                phx-target={@myself}
                class="btn btn-ghost btn-sm"
              >
                {gettext("Get a new link")}
              </button>
            </div>
          <% true -> %>
            <p :if={@link_dropped?} class="text-sm text-warning">
              {gettext(
                "Your Telegram was disconnected because the account was secured (a password change or signing out sessions). Connect it again to receive notifications there."
              )}
            </p>
            <p :if={@refusal in [:borrowed, :unspecified]} class="text-sm text-base-content/70">
              {refusal_message(@refusal)}
            </p>
            <p :if={@refusal == nil} class="text-sm text-base-content/70">
              {gettext(
                "Connect your Telegram chat to this account: open a link and press Start. It gets the notifications you pick, and the site's bot may let it read your data as you."
              )}
            </p>
            <button
              :if={@refusal == nil}
              type="button"
              phx-click="connect"
              phx-target={@myself}
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-paper-airplane" class="w-4 h-4" /> {gettext("Connect Telegram")}
            </button>
        <% end %>
      </div>
    </div>
    """
  end
end
