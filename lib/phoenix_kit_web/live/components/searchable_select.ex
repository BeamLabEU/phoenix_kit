defmodule PhoenixKitWeb.Live.Components.SearchableSelect do
  @moduledoc """
  Searchable select dropdown LiveComponent.

  A reusable dropdown with a search input that filters options in real-time.
  Supports flat options and grouped options (like `<optgroup>`).

  ## Usage — Flat options

      <.live_component
        module={PhoenixKitWeb.Live.Components.SearchableSelect}
        id="country-select"
        name="user[country]"
        value={@selected_country}
        placeholder="Search countries..."
        options={[{"United States", "us"}, {"United Kingdom", "uk"}, {"Germany", "de"}]}
      />

  ## Usage — Grouped options

      <.live_component
        module={PhoenixKitWeb.Live.Components.SearchableSelect}
        id="region-select"
        name="bucket[region]"
        value={@selected_region}
        placeholder="Search regions..."
        grouped_options={[
          {"North America", [{"US East (N. Virginia) — us-east-1", "us-east-1"}, ...]},
          {"Europe", [{"Europe (Frankfurt) — eu-central-1", "eu-central-1"}, ...]}
        ]}
      />

  ## Assigns

  - `id` (required) — unique component ID
  - `name` (required) — form field name for the hidden input
  - `value` (string) — currently selected value
  - `options` — flat list of `{label, value}` tuples
  - `grouped_options` — list of `{group_label, [{label, value}]}` tuples
  - `placeholder` — search input placeholder (default: "Search...")
  - `label` — optional label text above the input
  - `required` — whether the field is required (default: false)
  """

  use PhoenixKitWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open, false)
     |> assign(:search, "")
     |> assign(:internally_selected, false)}
  end

  @impl true
  def update(assigns, socket) do
    # Only accept parent's value if we haven't selected internally
    value =
      if socket.assigns[:internally_selected] do
        socket.assigns[:value]
      else
        assigns[:value]
      end

    socket =
      socket
      |> assign(Map.drop(assigns, [:value]))
      |> assign(:value, value)
      |> assign_new(:options, fn -> [] end)
      |> assign_new(:grouped_options, fn -> [] end)
      |> assign_new(:placeholder, fn -> "Search..." end)
      |> assign_new(:label, fn -> nil end)
      |> assign_new(:required, fn -> false end)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    {:noreply, assign(socket, :open, !socket.assigns.open)}
  end

  def handle_event("search", %{"search" => query}, socket) do
    {:noreply, assign(socket, :search, query)}
  end

  def handle_event("select", params, socket) do
    value = params["selected"]

    {:noreply,
     socket
     |> assign(:value, value)
     |> assign(:internally_selected, true)
     |> assign(:open, false)
     |> assign(:search, "")}
  end

  def handle_event("close", _params, socket) do
    {:noreply,
     socket
     |> assign(:open, false)
     |> assign(:search, "")}
  end

  @impl true
  def render(assigns) do
    selected_label = find_label(assigns)
    filtered = filter_options(assigns)

    assigns =
      assigns
      |> assign(:selected_label, selected_label)
      |> assign(:filtered, filtered)

    ~H"""
    <div class="form-control relative" id={@id}>
      <%= if @label do %>
        <label class="label">
          <span class="label-text font-semibold">{@label}</span>
        </label>
      <% end %>

      <input type="hidden" name={@name} value={@value || ""} />

      <%!-- Display input --%>
      <div
        class="input input-bordered flex items-center justify-between cursor-pointer"
        phx-click="toggle"
        phx-target={@myself}
      >
        <span class={if @value, do: "text-base-content", else: "text-base-content/50"}>
          {@selected_label || @placeholder}
        </span>
        <.icon
          name={if @open, do: "hero-chevron-up-mini", else: "hero-chevron-down-mini"}
          class="w-4 h-4 text-base-content/50"
        />
      </div>

      <%!-- Dropdown --%>
      <%= if @open do %>
        <div class="absolute top-full left-0 right-0 mt-1 bg-base-100 border border-base-300 rounded-lg shadow-xl max-h-64 overflow-hidden flex flex-col z-50">
          <%!-- Search input --%>
          <form
            phx-change="search"
            phx-target={@myself}
            phx-submit="search"
            class="p-2 border-b border-base-200"
          >
            <input
              type="text"
              value={@search}
              placeholder={@placeholder}
              class="input input-sm input-bordered w-full"
              name="search"
              autocomplete="off"
              autofocus
              phx-debounce="100"
              id={"#{@id}-search"}
            />
          </form>

          <%!-- Options list --%>
          <div class="overflow-y-auto max-h-52">
            <%= if @filtered == [] do %>
              <div class="p-3 text-sm text-base-content/50 text-center">
                No results found
              </div>
            <% else %>
              <%= for item <- @filtered do %>
                <%= case item do %>
                  <% {:group, group_label, options} -> %>
                    <div class="px-3 pt-2 pb-1 text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                      {group_label}
                    </div>
                    <%= for {opt_label, opt_val} <- options do %>
                      <button
                        type="button"
                        phx-click="select"
                        phx-value-selected={opt_val}
                        phx-target={@myself}
                        class={[
                          "w-full text-left px-3 py-2 text-sm hover:bg-base-200 cursor-pointer flex items-center justify-between",
                          @value == opt_val && "bg-primary/10 text-primary font-medium"
                        ]}
                      >
                        <span>{opt_label}</span>
                        <%= if @value == opt_val do %>
                          <.icon name="hero-check-mini" class="w-4 h-4 text-primary" />
                        <% end %>
                      </button>
                    <% end %>
                  <% {:option, opt_label, opt_val} -> %>
                    <button
                      type="button"
                      phx-click="select"
                      phx-value-selected={opt_val}
                      phx-target={@myself}
                      class={[
                        "w-full text-left px-3 py-2 text-sm hover:bg-base-200 cursor-pointer flex items-center justify-between",
                        @value == opt_val && "bg-primary/10 text-primary font-medium"
                      ]}
                    >
                      <span>{opt_label}</span>
                      <%= if @value == opt_val do %>
                        <.icon name="hero-check-mini" class="w-4 h-4 text-primary" />
                      <% end %>
                    </button>
                <% end %>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp find_label(assigns) do
    value = assigns.value

    if value && value != "" do
      find_in_flat(assigns.options, value) ||
        find_in_grouped(assigns.grouped_options, value)
    end
  end

  defp find_in_flat(options, value) do
    case Enum.find(options, fn {_label, v} -> v == value end) do
      {label, _} -> label
      nil -> nil
    end
  end

  defp find_in_grouped(groups, value) do
    Enum.find_value(groups, fn {_group, options} ->
      find_in_flat(options, value)
    end)
  end

  defp filter_options(assigns) do
    search = String.downcase(assigns.search || "")

    if assigns.grouped_options != [] do
      filter_grouped(assigns.grouped_options, search)
    else
      filter_flat(assigns.options, search)
    end
  end

  defp filter_flat(options, "") do
    Enum.map(options, fn {label, value} -> {:option, label, value} end)
  end

  defp filter_flat(options, search) do
    options
    |> Enum.filter(fn {label, value} ->
      String.contains?(String.downcase(label), search) ||
        String.contains?(String.downcase(value), search)
    end)
    |> Enum.map(fn {label, value} -> {:option, label, value} end)
  end

  defp filter_grouped(groups, "") do
    Enum.flat_map(groups, fn {group_label, options} ->
      [{:group, group_label, options}]
    end)
  end

  defp filter_grouped(groups, search) do
    groups
    |> Enum.map(fn {group_label, options} ->
      filtered =
        Enum.filter(options, fn {label, value} ->
          String.contains?(String.downcase(label), search) ||
            String.contains?(String.downcase(value), search) ||
            String.contains?(String.downcase(group_label), search)
        end)

      {group_label, filtered}
    end)
    |> Enum.reject(fn {_group, options} -> options == [] end)
    |> Enum.flat_map(fn {group_label, options} ->
      [{:group, group_label, options}]
    end)
  end
end
