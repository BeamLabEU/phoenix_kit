defmodule PhoenixKitWeb.Live.Notifications.Settings do
  @moduledoc """
  "My Settings" — the current user's notification preferences.

  The page is a single matrix: each notification type/sub-type is a row, and the
  **columns are the destinations** — In-app (the website inbox) and Email are
  always present (Email uses the account address, no setup), plus one column per
  additional channel (Telegram, …). A channel that needs connecting shows a
  **Connect** action in its header and disabled cells until it's linked.
  Destinations are independent — a type can go to Email but not the inbox, etc.

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
     |> assign_user(user)}
  end

  # ── Type-matrix events ─────────────────────────────────────────────────

  @impl true
  def handle_event("form_changed", %{"notification_prefs" => raw}, socket) do
    draft = Map.new(Types.all_pref_keys(), fn key -> {key, Map.get(raw, key) == "true"} end)
    {:noreply, assign(socket, :draft, draft)}
  end

  def handle_event("form_changed", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save", params, socket) do
    user = socket.assigns.user

    with {:ok, user} <-
           save_in_app(user, params["notification_prefs"] || %{}, socket.assigns.prefs),
         {:ok, user} <- save_channel_types(user, params["notification_channel"] || %{}) do
      {:noreply,
       socket
       |> assign_user(user)
       |> put_flash(:info, gettext("Notification preferences saved."))}
    else
      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not save notification preferences."))}
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

  defp save_in_app(user, raw, stored) do
    prefs =
      Map.new(Types.all_pref_keys(), fn key ->
        value =
          case Map.get(raw, key) do
            "true" -> true
            "false" -> false
            _ -> Map.get_lazy(stored, key, fn -> Types.default_for(key) end)
          end

        {key, value}
      end)

    Prefs.merge(user, prefs)
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
    |> assign(:draft, Map.new(Types.all_pref_keys(), fn key -> {key, enabled?(prefs, key)} end))
    |> assign_channels()
  end

  defp assign_user(socket, _), do: socket

  defp assign_channels(socket) do
    user = socket.assigns.user
    configs = ChannelConfig.all_for(user)
    channels = socket.assigns.channels

    # Only CONNECTED channels get a matrix column (Email is always connected).
    active = Enum.filter(channels, &configured_channel?(&1, configs, user.uuid))

    socket
    |> assign(:channel_configs, configs)
    |> assign(:active_channels, active)
  end

  defp configured_channel?(channel, configs, uuid),
    do: channel.configured?(uuid, Map.get(configs, channel.key(), %{}))

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
        <form id="notification-settings-form" phx-change="form_changed" phx-submit="save">
          <%!-- Column header: In-app + one per CONNECTED channel --%>
          <div class="flex items-center gap-3 px-4 pb-1">
            <div class="flex-1"></div>
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
          </div>

          <div class="space-y-4">
            <%= for type <- @types do %>
              <% master_on = @draft[type.key] %>
              <div class="card bg-base-100 shadow-sm border border-base-200 overflow-hidden">
                <div class="flex items-start gap-3 px-4 py-4">
                  <div class="flex-1 min-w-0">
                    <p class="font-medium text-sm">{Types.translate(type, :label)}</p>
                    <p
                      :if={type.description not in [nil, ""]}
                      class="text-xs text-base-content/60 mt-0.5"
                    >
                      {Types.translate(type, :description)}
                    </p>
                  </div>
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
                </div>

                <ul
                  :if={type.sub_types != []}
                  class="border-t border-base-200 divide-y divide-base-200 m-0 p-0 bg-base-200/30"
                >
                  <%= for sub <- type.sub_types do %>
                    <li class={[
                      "flex items-start gap-3 pl-8 pr-4 py-3 transition-opacity",
                      not master_on && "opacity-50 pointer-events-none"
                    ]}>
                      <div class="flex-1 min-w-0">
                        <p class="text-sm">{Types.translate(sub, :label)}</p>
                        <p
                          :if={sub.description not in [nil, ""]}
                          class="text-xs text-base-content/50 mt-0.5"
                        >
                          {Types.translate(sub, :description)}
                        </p>
                      </div>
                      <div class="w-14"></div>
                      <div class="w-16 flex justify-center">
                        <input type="hidden" name={"notification_prefs[#{sub.key}]"} value="false" />
                        <input
                          type="checkbox"
                          name={"notification_prefs[#{sub.key}]"}
                          value="true"
                          checked={@draft[sub.key]}
                          class="toggle toggle-primary toggle-sm"
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
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>
          </div>

          <div class="mt-5 flex justify-end">
            <button type="submit" class="btn btn-primary" phx-disable-with={gettext("Saving…")}>
              {gettext("Save preferences")}
            </button>
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
