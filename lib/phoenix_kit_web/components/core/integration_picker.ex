defmodule PhoenixKitWeb.Components.Core.IntegrationPicker do
  @moduledoc """
  Reusable integration connection picker component.

  Displays integration connections as clickable cards in a modal or inline grid.
  Supports single and multi-select modes, search, and provider filtering.

  ## Examples

      <%-- Single select, one provider --%>
      <.integration_picker
        id="google-picker"
        connections={@all_connections}
        selected={[@selected_uuid]}
        provider="google"
        on_select="select_integration"
      />

      <%-- Multi-select, all providers, with search --%>
      <.integration_picker
        id="multi-picker"
        connections={@all_connections}
        selected={@selected_uuids}
        multiple={true}
        searchable={true}
        on_select="update_integrations"
      />

      <%-- Single select, all providers --%>
      <.integration_picker
        id="any-picker"
        connections={@all_connections}
        selected={[@selected_uuid]}
        on_select="pick_integration"
      />

  The parent LiveView is responsible for loading connections via
  `PhoenixKit.Integrations.list_connections/1` or building the list
  from `PhoenixKit.Integrations.Providers.all/0`.

  ## Events

  The component sends the `on_select` event with:
  - Single mode: `%{"uuid" => uuid}` when a card is clicked
  - Multi mode: `%{"uuid" => uuid, "action" => "add" | "remove"}` when toggled
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @doc """
  Renders an integration picker as a grid of cards.

  ## Attributes

  * `id` - Unique element ID (required)
  * `connections` - List of connection maps from `Integrations.list_connections/1`.
    Each map must have `:uuid`, `:name`, `:data` keys, and optionally `:provider`
    (a provider definition map with `:name`, `:icon`, `:key`).
  * `selected` - List of currently selected UUIDs (default: [])
  * `provider` - Filter to only show connections for this provider key (optional)
  * `multiple` - Allow multiple selection (default: false)
  * `searchable` - Show search input (default: false, auto-enabled when > 6 connections)
  * `compact` - Use compact card layout (default: false)
  * `on_select` - Event name sent to parent on selection (required)
  * `empty_url` - URL for "Add Integration" link shown when no connections exist (optional)
  * `class` - Additional CSS classes for the wrapper (optional)
  """
  attr :id, :string, required: true
  attr :connections, :list, required: true
  attr :selected, :list, default: []
  attr :provider, :string, default: nil
  attr :multiple, :boolean, default: false
  attr :searchable, :any, default: nil
  attr :compact, :boolean, default: false
  attr :on_select, :string, required: true
  attr :empty_url, :string, default: nil
  attr :class, :string, default: ""
  attr :search, :string, default: ""

  def integration_picker(assigns) do
    connections =
      assigns.connections
      |> filter_by_provider(assigns.provider)
      |> filter_by_search(assigns.search)

    show_search =
      case assigns.searchable do
        nil -> length(assigns.connections) > 6
        val -> val
      end

    selected = auto_select(assigns.selected || [], connections)
    selected_set = MapSet.new(selected)
    existing_uuids = MapSet.new(Enum.map(connections, & &1.uuid))

    deleted_selections =
      Enum.filter(selected, fn uuid ->
        uuid && not MapSet.member?(existing_uuids, uuid)
      end)

    assigns =
      assigns
      |> assign(:filtered_connections, connections)
      |> assign(:deleted_selections, deleted_selections)
      |> assign(:show_search, show_search)
      |> assign(:selected_set, selected_set)

    ~H"""
    <div id={@id} class={["integration-picker", @class]}>
      <%!-- Search --%>
      <div :if={@show_search} class="mb-3">
        <input
          type="text"
          placeholder={gettext("Search integrations...")}
          value={@search}
          phx-keyup="integration_picker_search"
          phx-value-picker-id={@id}
          class="input input-bordered input-sm w-full"
        />
      </div>

      <%!-- Connection cards grid --%>
      <div
        :if={@filtered_connections != []}
        class={[
          "grid gap-2",
          if(@compact, do: "grid-cols-1", else: "grid-cols-1 sm:grid-cols-2 lg:grid-cols-3")
        ]}
      >
        <button
          :for={conn <- @filtered_connections}
          type="button"
          phx-click={@on_select}
          phx-value-uuid={conn.uuid}
          phx-value-action={select_action(@multiple, conn.uuid, @selected_set)}
          class={[
            "card bg-base-100 border text-left transition-all cursor-pointer",
            "hover:shadow-md hover:border-primary/50",
            if(MapSet.member?(@selected_set, conn.uuid),
              do: "border-primary ring-2 ring-primary/20",
              else: "border-base-300"
            )
          ]}
        >
          <div class={["card-body", if(@compact, do: "p-3", else: "p-4")]}>
            <div class="flex items-center gap-3">
              <%!-- Provider icon --%>
              <span
                :if={is_map(conn[:provider]) && conn.provider[:icon]}
                class="w-8 h-8 flex items-center justify-center bg-base-200 rounded-lg shrink-0"
              >
                <.icon name={conn.provider.icon} class="w-4 h-4" />
              </span>

              <div class="flex-1 min-w-0">
                <%!-- Connection name --%>
                <div class="flex items-center gap-2">
                  <span class="font-medium truncate">
                    {if conn.name == "default",
                      do:
                        if(is_map(conn[:provider]),
                          do: conn.provider.name,
                          else: conn.data["provider"] || gettext("Default")
                        ),
                      else: conn.name}
                  </span>
                  <span
                    :if={conn.name != "default" && is_map(conn[:provider])}
                    class="badge badge-ghost badge-xs shrink-0"
                  >
                    {conn.provider.name}
                  </span>
                </div>

                <%!-- Account info --%>
                <p
                  :if={conn.data["external_account_id"]}
                  class="text-xs text-base-content/60 truncate"
                >
                  {conn.data["external_account_id"]}
                </p>
              </div>

              <%!-- Status + selection indicator --%>
              <div class="flex items-center gap-2 shrink-0">
                <span :if={conn.data["status"] == "connected"} class="badge badge-success badge-xs">
                  {gettext("Connected")}
                </span>
                <span
                  :if={conn.data["status"] != "connected"}
                  class="badge badge-ghost badge-xs"
                >
                  {gettext("Not connected")}
                </span>

                <%!-- Selection check --%>
                <span :if={MapSet.member?(@selected_set, conn.uuid)}>
                  <.icon name="hero-check-circle-solid" class="w-5 h-5 text-primary" />
                </span>
              </div>
            </div>
          </div>
        </button>
      </div>

      <%!-- Deleted integration cards --%>
      <div
        :for={deleted_uuid <- @deleted_selections}
        class="card bg-error/5 border border-error/30 mt-2"
      >
        <div class={["card-body", if(@compact, do: "p-3", else: "p-4")]}>
          <div class="flex items-center gap-3">
            <div class="w-8 h-8 rounded-lg bg-error/10 flex items-center justify-center shrink-0">
              <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-error" />
            </div>
            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2">
                <span class="font-medium text-error">{gettext("Integration deleted")}</span>
                <span class="badge badge-error badge-xs">{gettext("Missing")}</span>
              </div>
              <p class="text-xs text-base-content/50 truncate">
                {gettext("The selected integration no longer exists. Please choose a different one.")}
              </p>
            </div>
          </div>
        </div>
      </div>

      <%!-- Empty state --%>
      <div
        :if={@filtered_connections == [] and @deleted_selections == []}
        class="text-center py-8 text-base-content/50"
      >
        <.icon name="hero-link" class="w-10 h-10 mx-auto mb-2 opacity-40" />
        <%= if @search != "" do %>
          <p class="text-sm">{gettext("No integrations match your search.")}</p>
        <% else %>
          <p class="text-sm">{gettext("No integrations configured.")}</p>
          <a
            :if={@empty_url}
            href={@empty_url}
            class="link link-primary text-sm"
          >
            {gettext("Add one in Settings → Integrations")}
          </a>
        <% end %>
      </div>
    </div>
    """
  end

  defp filter_by_provider(connections, nil), do: connections

  defp filter_by_provider(connections, provider) do
    Enum.filter(connections, fn conn ->
      key = conn_provider_key(conn)
      key == provider or String.starts_with?(key, provider <> ":")
    end)
  end

  defp conn_provider_key(conn) do
    cond do
      is_map(conn[:provider]) -> conn.provider.key
      is_binary(conn[:provider_key]) -> conn.provider_key
      true -> conn.data["provider"] || ""
    end
  end

  defp filter_by_search(connections, ""), do: connections
  defp filter_by_search(connections, nil), do: connections

  defp filter_by_search(connections, search) do
    q = String.downcase(search)

    Enum.filter(connections, fn conn ->
      name = String.downcase(conn.name || "")
      account = String.downcase(conn.data["external_account_id"] || "")

      provider_name =
        if is_map(conn[:provider]),
          do: String.downcase(conn.provider.name || ""),
          else: String.downcase(conn.data["provider"] || "")

      String.contains?(name, q) or String.contains?(account, q) or
        String.contains?(provider_name, q)
    end)
  end

  defp auto_select([], [single]), do: [single.uuid]
  defp auto_select(selected, _connections), do: selected

  defp select_action(true, uuid, selected_set) do
    if MapSet.member?(selected_set, uuid), do: "remove", else: "add"
  end

  defp select_action(false, _uuid, _selected_set), do: "select"
end
