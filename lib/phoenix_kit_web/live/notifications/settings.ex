defmodule PhoenixKitWeb.Live.Notifications.Settings do
  @moduledoc """
  "My Settings" — the current user's notification preferences.

  The page is a single matrix: each notification type/sub-type is a row, and the
  **columns are the destinations** — In-app (the website inbox) and Email are
  always present (Email uses the account address, no setup), plus one column per
  additional channel (Telegram, …). A channel that needs connecting shows a
  **Connect** link in its header (`Channel.connect_path/0`) and disabled cells
  until it's linked. Destinations are independent — a type can go to Email but
  not the inbox, etc.

  Each row names what it covers: its label, its description and, when the type
  declares one, an `example` ("“Fit the doors” is marked “Can be started”"),
  so a reader can tell which line sent a notification. Every row has an anchor
  (`notif-<key>`); a notification's "why you got this" line links to it.

  **Every switch saves when it is flipped** and the page says so ("Saved"): the
  matrix is drawn from what is stored, never from a draft. (It used to keep a
  draft until a Save button, and drew the channel columns from what was
  stored: a channel switch flipped back as soon as the page redrew — the boss,
  2026-11-18, "when you initially flip a toggle, it just untoggles".)

  Each type also has an **Aggregate** control opening a popup where the delivery
  cadence per push channel is chosen (Immediate / Hourly / 12h / Daily / Weekly)
  — so "1,432 likes/hour" becomes one hourly summary instead of a flood.

  In-app routing lives in `notification_preferences`; per-channel routing +
  cadence live in `notification_channel:<key>`. Access is gated by the base
  `notifications` permission; the scope's user is always the subject.
  """
  use PhoenixKitWeb, :live_view

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Channels
  alias PhoenixKit.Notifications.Prefs
  alias PhoenixKit.Notifications.Types
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    user = Scope.user(socket.assigns[:phoenix_kit_current_scope])

    {:ok,
     socket
     |> assign(:page_title, gettext("My Settings"))
     |> assign(:project_title, Settings.get_project_title())
     |> assign(:url_path, Routes.path("/admin/notifications/settings"))
     |> assign(:types, Types.shown())
     |> assign(:channels, Channels.list())
     |> assign(:modal, nil)
     |> assign(:saved_at, nil)
     |> assign(:save_failed, false)
     |> assign_user(user)}
  end

  # ── Type-matrix events ─────────────────────────────────────────────────

  # A switch flipped: saved at once, and the page redrawn from what was
  # stored. `save` is the same for a submitted form (Enter, no JS).
  @impl true
  def handle_event(event, params, socket) when event in ["form_changed", "save"] do
    user = socket.assigns.user
    params = only_target(params)

    with {:ok, user} <-
           save_in_app(user, params["notification_prefs"] || %{}, socket.assigns.prefs),
         {:ok, user} <- save_channel_types(user, params["notification_channel"] || %{}) do
      {:noreply,
       socket
       |> assign_user(user)
       |> assign(saved_at: DateTime.utc_now(), save_failed: false)}
    else
      _ ->
        # Redrawn from what is stored, so the switch shows the truth.
        {:noreply,
         socket
         |> assign_user(Auth.get_user(user.uuid) || user)
         |> assign(save_failed: true)}
    end
  end

  # ── Modals ──────────────────────────────────────────────────────────────

  def handle_event("open_aggregate", %{"type" => type_key}, socket),
    do: {:noreply, assign(socket, :modal, {:aggregate, type_key})}

  def handle_event("close_modal", _params, socket), do: {:noreply, assign(socket, :modal, nil)}

  def handle_event("save_cadences", params, socket) do
    user = socket.assigns.user

    result =
      params["cadence"]
      |> known_channel_params(cadence_mode_keys())
      |> Enum.reduce_while({:ok, user}, fn {channel_key, leaf_map}, {:ok, u} ->
        cadences =
          leaf_map
          |> known_type_params()
          |> Map.new(fn {leaf, c} -> {leaf, sanitize_cadence(c)} end)

        case ChannelConfig.update(u, channel_key, fn config ->
               Map.put(config, "cadences", Map.merge(config["cadences"] || %{}, cadences))
             end) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign_user(user)
         |> assign(:modal, nil)
         |> put_flash(:info, gettext("Aggregation updated."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not update aggregation."))}
    end
  end

  # ── Internals ────────────────────────────────────────────────────────

  # A change event saves the ONE switch that was flipped (`_target`), never
  # the whole form: a second tab still showing an older state would
  # otherwise write it back over what the first tab saved since.
  defp only_target(%{"_target" => ["notification_prefs", key]} = params) when is_binary(key),
    do: %{"notification_prefs" => Map.take(params["notification_prefs"] || %{}, [key])}

  defp only_target(%{"_target" => ["notification_channel", channel, "types", key]} = params)
       when is_binary(channel) and is_binary(key) do
    value = get_in(params, ["notification_channel", channel, "types", key])
    %{"notification_channel" => %{channel => %{"types" => %{key => value}}}}
  end

  defp only_target(%{"_target" => _} = _params), do: %{}
  defp only_target(params), do: params

  # Only the keys posted, merged over what is stored now (`Prefs.merge/2`
  # reads the user's current preferences): a key this page did not post is
  # never written from its own, possibly older, copy.
  defp save_in_app(user, raw, _stored) do
    prefs =
      for key <- Types.all_pref_keys(),
          value = Map.get(raw, key),
          value in ["true", "false"],
          into: %{},
          do: {key, value == "true"}

    if prefs == %{}, do: {:ok, user}, else: Prefs.merge(Auth.get_user(user.uuid) || user, prefs)
  end

  defp save_channel_types(user, channel_params) do
    channel_params
    |> known_channel_params(Channels.keys())
    |> Enum.reduce_while({:ok, user}, fn {channel_key, cfg}, {:ok, acc_user} ->
      new_types =
        case is_map(cfg) && cfg["types"] do
          %{} = types ->
            types |> known_type_params() |> Map.new(fn {k, v} -> {k, v == "true"} end)

          _ ->
            %{}
        end

      case ChannelConfig.update(acc_user, channel_key, fn config ->
             Map.put(config, "types", Map.merge(config["types"] || %{}, new_types))
           end) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        error -> {:halt, error}
      end
    end)
  end

  # Form params name their own keys, so both the channel and the type key are
  # attacker-controlled on a crafted event. Anything not in the live registry is
  # dropped rather than persisted — otherwise a hand-rolled submit writes
  # arbitrary `notification_channel:<key>` blobs (and arbitrary type/cadence
  # entries inside them) into the user's `custom_fields` JSONB forever.
  defp known_channel_params(params, allowed) when is_map(params),
    do: Map.take(params, allowed)

  defp known_channel_params(_params, _allowed), do: %{}

  defp known_type_params(params) when is_map(params),
    do: Map.take(params, Types.all_pref_keys())

  defp known_type_params(_params), do: %{}

  # Cadence is set per delivery MODE: the synthetic in-app inbox plus every
  # registered channel (mirrors `aggregate_body/1`'s `@modes`).
  defp cadence_mode_keys, do: ["inapp" | Channels.keys()]

  defp sanitize_cadence(c), do: if(c in ChannelConfig.cadences(), do: c, else: "immediate")

  defp assign_user(socket, %{} = user) do
    prefs = Prefs.get(user)

    socket
    |> assign(:user, user)
    |> assign(:prefs, prefs)
    |> assign(:on, Map.new(Types.all_pref_keys(), fn key -> {key, enabled?(prefs, key)} end))
    |> assign_channels()
  end

  defp assign_user(socket, _), do: socket

  defp assign_channels(socket) do
    user = socket.assigns.user
    configs = ChannelConfig.all_for(user)
    channels = socket.assigns.channels

    # CONNECTED channels get a column of switches (Email is always connected);
    # one that can be connected gets a column with a Connect link and
    # disabled cells.
    {active, rest} = Enum.split_with(channels, &configured_channel?(&1, configs, user.uuid))
    connectable = for channel <- rest, path = connect_path(channel), do: {channel, path}

    socket
    |> assign(:channel_configs, configs)
    |> assign(:active_channels, active)
    |> assign(:connectable_channels, connectable)
  end

  defp configured_channel?(channel, configs, uuid),
    do: channel.configured?(uuid, Map.get(configs, channel.key(), %{}))

  defp connect_path(channel) do
    if function_exported?(channel, :connect_path, 0), do: channel.connect_path()
  rescue
    _ -> nil
  end

  @doc false
  # The DOM id of a type's or sub-type's row: what a notification's "why you
  # got this" link points at (`PhoenixKit.Notifications.Render.reason/2`).
  # The key as it is: a sub-type's dot keeps it apart from a type whose
  # own key has a dash in that place.
  def row_id(key), do: "notif-" <> key

  defp enabled?(prefs, key) do
    case Map.get(prefs, key) do
      v when is_boolean(v) -> v
      _ -> Types.default_for(key)
    end
  end

  defp channel_type_on?(configs, channel_key, type_key),
    do: ChannelConfig.type_enabled?(Map.get(configs, channel_key, %{}), type_key)

  # Leaf routable keys for a type: its sub-types, or the base itself if none.
  defp leaves(%{sub_types: []} = type),
    do: [%{key: type.key, label: Types.translate(type, :label)}]

  defp leaves(%{sub_types: subs}),
    do: Enum.map(subs, &%{key: &1.key, label: Types.translate(&1, :label)})

  defp cadence_of(configs, channel_key, type_key),
    do: ChannelConfig.cadence(Map.get(configs, channel_key, %{}), type_key)

  # DOM id of a type's kept-in-DOM aggregate dialog (trigger + modal share it).
  defp agg_id(type_key), do: "pk-agg-" <> type_key

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={gettext("My Settings")}
      page_subtitle={gettext("Choose which notifications you receive, and where")}
      current_path={@url_path}
      project_title={@project_title}
      current_locale={assigns[:current_locale]}
    >
      <div class="p-6 max-w-3xl mx-auto space-y-4">
        <%!-- No form recovery: a reconnect would replay the page's old
             switches as a change and overwrite what was saved since. --%>
        <form
          id="notification-settings-form"
          phx-change="form_changed"
          phx-submit="save"
          phx-auto-recover="ignore"
        >
          <%!-- Column header: In-app + one per CONNECTED channel, then the
               channels that can still be connected, with the link. --%>
          <div class="flex items-end gap-3 px-4 pb-1">
            <div class="flex-1 min-w-0">
              <p
                :if={@saved_at && not @save_failed}
                id="notification-settings-saved"
                class="text-xs text-success flex items-center gap-1"
                role="status"
              >
                <.icon name="hero-check" class="w-3.5 h-3.5" /> {gettext("Saved")}
              </p>
              <p
                :if={@save_failed}
                id="notification-settings-failed"
                class="text-xs text-error flex items-center gap-1"
                role="alert"
              >
                <.icon name="hero-exclamation-triangle" class="w-3.5 h-3.5" />
                {gettext("Could not save — the switches show what is stored.")}
              </p>
            </div>
            <div class="w-14"></div>
            <div class="w-16 text-center text-[11px] font-medium text-base-content/50 uppercase tracking-wide">
              {gettext("In-app")}
            </div>
            <div
              :for={channel <- @active_channels}
              class="w-16 text-center text-[11px] font-medium text-base-content/50 uppercase tracking-wide"
            >
              {channel.label()}
            </div>
            <div
              :for={{channel, path} <- @connectable_channels}
              class="w-16 text-center text-[11px] font-medium text-base-content/50 uppercase tracking-wide"
              data-connect={channel.key()}
            >
              {channel.label()}
              <.link
                navigate={path}
                class="block normal-case tracking-normal text-primary link link-hover"
              >
                {gettext("Connect")}
              </.link>
            </div>
          </div>

          <div class="space-y-4">
            <%= for type <- @types do %>
              <% master_on = @on[type.key] %>
              <div
                id={row_id(type.key)}
                class="card bg-base-100 shadow-sm border border-base-200 overflow-hidden scroll-mt-24 target:ring-2 target:ring-primary"
              >
                <div class="flex items-start gap-3 px-4 py-4">
                  <.line_text item={type} />
                  <%!-- Aggregate popup trigger — opens the kept-in-DOM dialog
                         client-side (instant) the same frame as the click, with
                         the server push only syncing state behind it. --%>
                  <div class="w-14 flex justify-center">
                    <button
                      type="button"
                      phx-click={
                        JS.dispatch("pk:dialog-show", to: "##{agg_id(type.key)}")
                        |> JS.push("open_aggregate", value: %{type: type.key})
                      }
                      class="btn btn-ghost btn-xs gap-1"
                      title={gettext("Aggregation")}
                    >
                      <.icon name="hero-clock" class="w-4 h-4" />
                    </button>
                  </div>
                  <div class="w-16 flex justify-center">
                    <input type="hidden" name={"notification_prefs[#{type.key}]"} value="false" />
                    <input
                      type="checkbox"
                      name={"notification_prefs[#{type.key}]"}
                      value="true"
                      checked={master_on}
                      class="toggle toggle-primary"
                      aria-label={
                        gettext("%{line} in the inbox", line: Types.translate(type, :label))
                      }
                    />
                  </div>
                  <div :for={channel <- @active_channels} class="w-16 flex justify-center">
                    <.channel_cell
                      :if={type.sub_types == []}
                      channel={channel}
                      type_key={type.key}
                      on?={channel_type_on?(@channel_configs, channel.key(), type.key)}
                    />
                  </div>
                  <div
                    :for={{channel, _path} <- @connectable_channels}
                    class="w-16 flex justify-center"
                  >
                    <.unconnected_cell :if={type.sub_types == []} channel={channel} />
                  </div>
                </div>

                <ul
                  :if={type.sub_types != []}
                  class="border-t border-base-200 divide-y divide-base-200 m-0 p-0 bg-base-200/30"
                >
                  <%= for sub <- type.sub_types do %>
                    <li
                      id={row_id(sub.key)}
                      class={[
                        "flex items-start gap-3 pl-8 pr-4 py-3 transition-opacity scroll-mt-24 target:bg-primary/10",
                        not master_on && "opacity-50 pointer-events-none"
                      ]}
                    >
                      <.line_text item={sub} sub />
                      <div class="w-14"></div>
                      <div class="w-16 flex justify-center">
                        <%!-- Under a master switched off: not posted at all (the
                             stored value stands) and out of the tab order. --%>
                        <input
                          type="hidden"
                          name={"notification_prefs[#{sub.key}]"}
                          value="false"
                          disabled={not master_on}
                        />
                        <input
                          type="checkbox"
                          name={"notification_prefs[#{sub.key}]"}
                          value="true"
                          checked={@on[sub.key]}
                          disabled={not master_on}
                          class="toggle toggle-primary toggle-sm"
                          aria-label={
                            gettext("%{line} in the inbox", line: Types.translate(sub, :label))
                          }
                        />
                      </div>
                      <div :for={channel <- @active_channels} class="w-16 flex justify-center">
                        <.channel_cell
                          channel={channel}
                          type_key={sub.key}
                          on?={channel_type_on?(@channel_configs, channel.key(), sub.key)}
                          small
                        />
                      </div>
                      <div
                        :for={{channel, _path} <- @connectable_channels}
                        class="w-16 flex justify-center"
                      >
                        <.unconnected_cell channel={channel} small />
                      </div>
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>
          </div>
        </form>
      </div>

      <%!-- Aggregate dialogs — one per type, kept in the DOM so the trigger can
           open them instantly client-side (no round-trip to render). --%>
      <.modal
        :for={type <- @types}
        id={agg_id(type.key)}
        show={@modal == {:aggregate, type.key}}
        on_close="close_modal"
        keep_in_dom
        max_width="lg"
      >
        <:title>{gettext("Aggregation")} — {Types.translate(type, :label)}</:title>
        <.aggregate_body type={type} channels={@active_channels} configs={@channel_configs} />
      </.modal>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  attr :item, :map, required: true
  attr :sub, :boolean, default: false

  # A line's name, what it covers and, when declared, one example of it.
  defp line_text(assigns) do
    ~H"""
    <div class="flex-1 min-w-0">
      <p class={if(@sub, do: "text-sm", else: "font-medium text-sm")}>
        {Types.translate(@item, :label)}
      </p>
      <p :if={@item.description not in [nil, ""]} class="text-xs text-base-content/60 mt-0.5">
        {Types.translate(@item, :description)}
      </p>
      <p
        :if={Map.get(@item, :example) not in [nil, ""]}
        class="text-xs text-base-content/50 mt-0.5 italic"
        data-example
      >
        {gettext("For example: %{example}", example: Types.translate(@item, :example))}
      </p>
    </div>
    """
  end

  attr :channel, :any, required: true
  attr :small, :boolean, default: false

  # A channel not connected yet: a switch that cannot be flipped, with why.
  defp unconnected_cell(assigns) do
    ~H"""
    <input
      type="checkbox"
      disabled
      class={["toggle", @small && "toggle-sm"]}
      title={gettext("Connect %{channel} first", channel: @channel.label())}
      aria-label={gettext("Connect %{channel} first", channel: @channel.label())}
    />
    """
  end

  # A single channel routing toggle. Only rendered for CONNECTED channels
  # (unconnected ones have no column), so it's always an active toggle.
  # Styled exactly like the In-app toggle beside it (same colour, same size
  # per row): a channel column in `toggle-accent` read as a different kind of
  # switch.
  attr :channel, :any, required: true
  attr :type_key, :string, required: true
  attr :on?, :boolean, required: true
  attr :small, :boolean, default: false

  defp channel_cell(assigns) do
    ~H"""
    <input
      type="hidden"
      name={"notification_channel[#{@channel.key()}][types][#{@type_key}]"}
      value="false"
    />
    <input
      type="checkbox"
      name={"notification_channel[#{@channel.key()}][types][#{@type_key}]"}
      value="true"
      checked={@on?}
      class={["toggle toggle-primary", @small && "toggle-sm"]}
    />
    """
  end

  # ── Aggregate body (rendered inside a core `<.modal keep_in_dom>`) ───────

  attr :type, :any, required: true
  attr :channels, :list, required: true
  attr :configs, :map, required: true

  defp aggregate_body(assigns) do
    # Each delivery mode gets an independent cadence: In-app (the inbox) first,
    # then each connected push channel. In-app on a digest cadence collapses to
    # one "N this hour" inbox row instead of a row per event.
    assigns =
      assign(
        assigns,
        :modes,
        [{"inapp", gettext("In-app")} | Enum.map(assigns.channels, &{&1.key(), &1.label()})]
      )

    ~H"""
    <p class="text-xs text-base-content/60 mb-4">
      {gettext("Batch high-volume types into periodic summaries — set a cadence per delivery mode.")}
    </p>

    <form phx-submit="save_cadences" class="space-y-4">
      <div :for={leaf <- leaves(@type)} class="border-b border-base-200 pb-3 last:border-0">
        <p class="text-sm font-medium mb-2">{leaf.label}</p>
        <div class="grid grid-cols-2 gap-3">
          <.select
            :for={{mode_key, mode_label} <- @modes}
            name={"cadence[#{mode_key}][#{leaf.key}]"}
            label={mode_label}
            value={cadence_of(@configs, mode_key, leaf.key)}
            options={Enum.map(ChannelConfig.cadences(), &{cadence_label(&1), &1})}
            class="select-sm"
          />
        </div>
      </div>

      <div class="flex justify-end gap-2 pt-1">
        <button type="button" phx-click="close_modal" class="btn btn-ghost btn-sm">
          {gettext("Cancel")}
        </button>
        <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
      </div>
    </form>
    """
  end

  defp cadence_label("immediate"), do: gettext("Immediate")
  defp cadence_label("hourly"), do: gettext("Hourly")
  defp cadence_label("12h"), do: gettext("Every 12 hours")
  defp cadence_label("daily"), do: gettext("Daily")
  defp cadence_label("weekly"), do: gettext("Weekly")
  defp cadence_label(other), do: other
end
