defmodule PhoenixKit.Modules.Shop.Web.OptionsSettings do
  @moduledoc """
  Global product options settings LiveView.

  Allows administrators to manage global options that apply to all products.
  Supports both fixed and percentage-based price modifiers.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop.Options
  alias PhoenixKit.Modules.Shop.OptionTypes
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    options = Options.get_global_options()

    socket =
      socket
      |> assign(:page_title, "Product Options")
      |> assign(:options, options)
      |> assign(:show_modal, false)
      |> assign(:editing_option, nil)
      |> assign(:form_data, initial_form_data())
      |> assign(:supported_types, OptionTypes.supported_types())
      |> assign(:modifier_types, OptionTypes.modifier_types())

    {:ok, socket}
  end

  @impl true
  def handle_event("show_add_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:editing_option, nil)
     |> assign(:form_data, initial_form_data())}
  end

  @impl true
  def handle_event("show_edit_modal", %{"key" => key}, socket) do
    option = Enum.find(socket.assigns.options, &(&1["key"] == key))

    if option do
      form_data = %{
        key: option["key"],
        label: option["label"],
        type: option["type"],
        options: option["options"] || [],
        required: option["required"] || false,
        unit: option["unit"] || "",
        affects_price: option["affects_price"] || false,
        modifier_type: option["modifier_type"] || "fixed",
        price_modifiers: option["price_modifiers"] || %{},
        allow_override: option["allow_override"] || false,
        enabled: Map.get(option, "enabled", true)
      }

      {:noreply,
       socket
       |> assign(:show_modal, true)
       |> assign(:editing_option, option)
       |> assign(:form_data, form_data)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:editing_option, nil)
     |> assign(:form_data, initial_form_data())}
  end

  @impl true
  def handle_event("validate_form", %{"option" => params}, socket) do
    options = parse_options(params["options"])

    form_data = %{
      key: params["key"] || "",
      label: params["label"] || "",
      type: params["type"] || "text",
      options: options,
      required: params["required"] == "true",
      unit: params["unit"] || "",
      affects_price: params["affects_price"] == "true",
      modifier_type: params["modifier_type"] || "fixed",
      price_modifiers: parse_price_modifiers(params["price_modifiers"], options),
      allow_override: params["allow_override"] == "true"
    }

    # Auto-generate key from label if creating new
    form_data =
      if socket.assigns.editing_option == nil and form_data.key == "" do
        %{form_data | key: slugify_key(form_data.label)}
      else
        form_data
      end

    {:noreply, assign(socket, :form_data, form_data)}
  end

  @impl true
  def handle_event("toggle_affects_price", _params, socket) do
    form_data = socket.assigns.form_data
    updated = %{form_data | affects_price: !form_data.affects_price}

    # Initialize price modifiers with "0" for all options when enabling
    updated =
      if updated.affects_price and map_size(updated.price_modifiers) == 0 do
        modifiers = Map.new(updated.options, fn opt -> {opt, "0"} end)
        %{updated | price_modifiers: modifiers}
      else
        updated
      end

    {:noreply, assign(socket, :form_data, updated)}
  end

  @impl true
  def handle_event("set_modifier_type", %{"type" => type}, socket) do
    form_data = socket.assigns.form_data
    updated = %{form_data | modifier_type: type}
    {:noreply, assign(socket, :form_data, updated)}
  end

  @impl true
  def handle_event("toggle_allow_override", _params, socket) do
    form_data = socket.assigns.form_data
    updated = %{form_data | allow_override: !form_data.allow_override}
    {:noreply, assign(socket, :form_data, updated)}
  end

  @impl true
  def handle_event("save_option", %{"option" => params}, socket) do
    form_data = parse_form_params(params)
    opt = build_option(form_data)

    current = socket.assigns.options
    editing = socket.assigns.editing_option

    result =
      if editing do
        updated =
          Enum.map(current, fn o ->
            if o["key"] == editing["key"], do: Map.merge(o, opt), else: o
          end)

        Options.update_global_options(updated)
      else
        opt = Map.put(opt, "position", length(current))
        Options.add_global_option(opt)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:options, Options.get_global_options())
         |> assign(:show_modal, false)
         |> assign(:editing_option, nil)
         |> assign(:form_data, initial_form_data())
         |> put_flash(:info, if(editing, do: "Option updated", else: "Option created"))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{reason}")}
    end
  end

  @impl true
  def handle_event("delete_option", %{"key" => key}, socket) do
    case Options.remove_global_option(key) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:options, Options.get_global_options())
         |> put_flash(:info, "Option deleted")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{reason}")}
    end
  end

  @impl true
  def handle_event("toggle_enabled", %{"key" => key}, socket) do
    current = socket.assigns.options

    updated =
      Enum.map(current, fn opt ->
        if opt["key"] == key do
          current_enabled = Map.get(opt, "enabled", true)
          Map.put(opt, "enabled", !current_enabled)
        else
          opt
        end
      end)

    case Options.update_global_options(updated) do
      {:ok, _} ->
        toggled = Enum.find(updated, &(&1["key"] == key))
        label = if Map.get(toggled, "enabled", true), do: "enabled", else: "disabled"

        {:noreply,
         socket
         |> assign(:options, Options.get_global_options())
         |> put_flash(:info, "Option #{key} #{label}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Error: #{reason}")}
    end
  end

  @impl true
  def handle_event("reorder_options", %{"ordered_ids" => ordered_keys}, socket) do
    current = socket.assigns.options

    # Reorder options based on new order
    reordered =
      ordered_keys
      |> Enum.with_index()
      |> Enum.map(fn {key, idx} ->
        opt = Enum.find(current, &(&1["key"] == key))
        if opt, do: Map.put(opt, "position", idx), else: nil
      end)
      |> Enum.reject(&is_nil/1)

    case Options.update_global_options(reordered) do
      {:ok, _} ->
        {:noreply, assign(socket, :options, Options.get_global_options())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reorder failed: #{reason}")}
    end
  end

  @impl true
  def handle_event("add_option", _params, socket) do
    form_data = socket.assigns.form_data
    updated = %{form_data | options: form_data.options ++ [""]}
    {:noreply, assign(socket, :form_data, updated)}
  end

  @impl true
  def handle_event("remove_option", %{"index" => idx}, socket) do
    form_data = socket.assigns.form_data
    index = String.to_integer(idx)
    updated = %{form_data | options: List.delete_at(form_data.options, index)}
    {:noreply, assign(socket, :form_data, updated)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      current_path={@url_path}
      current_locale={@current_locale}
      page_title={@page_title}
    >
      <div class="container flex-col mx-auto px-4 py-6 max-w-5xl">
        <%!-- Header --%>
        <header class="w-full relative mb-8">
          <.link
            navigate={Routes.path("/admin/shop/settings")}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
          </.link>
          <div class="text-center pt-10 sm:pt-0">
            <h1 class="text-3xl font-bold text-base-content">Product Options</h1>
            <p class="text-base-content/70 mt-1">
              Define global options that apply to all products
            </p>
          </div>
        </header>

        <%!-- Controls Bar --%>
        <div class="bg-base-200 rounded-lg p-4 mb-6">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2 text-sm text-base-content/70">
              <.icon name="hero-information-circle" class="w-4 h-4" />
              <span>
                Global options apply to all products. Categories can override or add their own.
              </span>
            </div>
            <button type="button" phx-click="show_add_modal" class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4 mr-1" /> Add Option
            </button>
          </div>
        </div>

        <%!-- Options List --%>
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <div class="flex items-center justify-between mb-4">
              <h2 class="card-title text-lg">
                <.icon name="hero-adjustments-horizontal" class="w-5 h-5" /> Global Options
              </h2>
              <span class="text-sm text-base-content/60">
                {length(@options)} {if length(@options) == 1, do: "option", else: "options"}
              </span>
            </div>

            <%= if @options == [] do %>
              <div class="text-center py-12">
                <.icon
                  name="hero-adjustments-horizontal"
                  class="w-16 h-16 mx-auto text-base-content/30 mb-4"
                />
                <h3 class="text-lg font-medium text-base-content mb-2">
                  No options defined yet
                </h3>
                <p class="text-base-content/60 mb-4">
                  Add your first global option to get started
                </p>
                <button type="button" phx-click="show_add_modal" class="btn btn-primary">
                  <.icon name="hero-plus" class="w-4 h-4 mr-2" /> Create First Option
                </button>
              </div>
            <% else %>
              <%!-- Table Header --%>
              <div class="hidden sm:flex items-center px-4 py-2 text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                <div class="flex-1">Option</div>
                <div class="w-52 text-right">Actions</div>
              </div>

              <div class="flex flex-col gap-2">
                <%= for opt <- @options do %>
                  <% enabled = Map.get(opt, "enabled", true) != false %>
                  <div class={[
                    "flex flex-col sm:flex-row sm:items-center p-4 rounded-lg border transition-all",
                    if(enabled,
                      do: "bg-base-200/60 border-base-300 hover:bg-base-200",
                      else: "bg-base-200/30 border-base-300/50 opacity-60"
                    )
                  ]}>
                    <%!-- Content --%>
                    <div class="flex-1 min-w-0">
                      <div class="flex flex-wrap items-center gap-2">
                        <span class={[
                          "font-semibold",
                          if(!enabled, do: "line-through text-base-content/50")
                        ]}>
                          {opt["label"]}
                        </span>
                        <span class="badge badge-ghost badge-sm font-mono">{opt["type"]}</span>
                        <%= if !enabled do %>
                          <span class="badge badge-neutral badge-sm">Disabled</span>
                        <% end %>
                        <%= if opt["required"] do %>
                          <span class="badge badge-warning badge-sm">Required</span>
                        <% end %>
                        <%= if opt["unit"] do %>
                          <span class="badge badge-outline badge-sm">{opt["unit"]}</span>
                        <% end %>
                        <%= if opt["affects_price"] do %>
                          <span class="badge badge-success badge-sm">
                            {opt["modifier_type"] || "fixed"}
                          </span>
                          <%= if opt["allow_override"] do %>
                            <span class="badge badge-info badge-sm">Override</span>
                          <% end %>
                        <% end %>
                      </div>
                      <div class="flex flex-wrap items-center gap-x-3 gap-y-1 mt-1 text-sm text-base-content/50">
                        <code class="bg-base-300/60 px-1.5 py-0.5 rounded text-xs">
                          {opt["key"]}
                        </code>
                        <%= if opt["options"] && opt["options"] != [] do %>
                          <span class="truncate max-w-xs" title={format_options_with_modifiers(opt)}>
                            {format_options_with_modifiers(opt)}
                          </span>
                        <% end %>
                      </div>
                    </div>

                    <%!-- Actions Column --%>
                    <div class="flex items-center gap-1 mt-3 sm:mt-0 sm:ml-4 shrink-0">
                      <label
                        class="swap swap-rotate btn btn-ghost btn-sm tooltip tooltip-bottom"
                        data-tip={if enabled, do: "Disable", else: "Enable"}
                      >
                        <input
                          type="checkbox"
                          checked={enabled}
                          phx-click="toggle_enabled"
                          phx-value-key={opt["key"]}
                        />
                        <.icon name="hero-eye" class="swap-on w-4 h-4 text-success" />
                        <.icon name="hero-eye-slash" class="swap-off w-4 h-4 text-base-content/40" />
                      </label>
                      <button
                        type="button"
                        phx-click="show_edit_modal"
                        phx-value-key={opt["key"]}
                        class="btn btn-ghost btn-sm tooltip tooltip-bottom"
                        data-tip="Edit"
                      >
                        <.icon name="hero-pencil" class="w-4 h-4" />
                      </button>
                      <button
                        type="button"
                        phx-click="delete_option"
                        phx-value-key={opt["key"]}
                        data-confirm="Delete this option? This cannot be undone."
                        class="btn btn-ghost btn-sm text-error tooltip tooltip-bottom"
                        data-tip="Delete"
                      >
                        <.icon name="hero-trash" class="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Reference Section (collapsible) --%>
        <div class="collapse collapse-arrow bg-base-200/50 mt-6">
          <input type="checkbox" />
          <div class="collapse-title font-medium text-sm flex items-center gap-2">
            <.icon name="hero-book-open" class="w-4 h-4" /> Option Types Reference
          </div>
          <div class="collapse-content">
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4 pt-2">
              <div>
                <h4 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-2">
                  Input Types
                </h4>
                <div class="flex flex-wrap gap-1.5">
                  <span class="badge badge-sm">text</span>
                  <span class="badge badge-sm">number</span>
                  <span class="badge badge-sm">boolean</span>
                  <span class="badge badge-sm">select</span>
                  <span class="badge badge-sm">multiselect</span>
                </div>
              </div>
              <div>
                <h4 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-2">
                  Price Modifiers
                </h4>
                <div class="flex flex-wrap gap-1.5">
                  <span class="badge badge-success badge-sm">fixed (+10)</span>
                  <span class="badge badge-info badge-sm">percent (+20%)</span>
                </div>
                <p class="text-xs text-base-content/50 mt-1.5">
                  Enable "Allow Override" for per-product values
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Modal for Add/Edit Option --%>
      <%= if @show_modal do %>
        <div class="modal modal-open">
          <div class="modal-box max-w-lg">
            <button
              type="button"
              phx-click="close_modal"
              class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
            <h3 class="font-bold text-lg mb-4">
              {if @editing_option, do: "Edit Option", else: "Add Option"}
            </h3>

            <.form for={%{}} phx-change="validate_form" phx-submit="save_option" class="space-y-4">
              <%!-- Label --%>
              <div class="form-control">
                <label class="label"><span class="label-text">Label *</span></label>
                <input
                  type="text"
                  name="option[label]"
                  value={@form_data.label}
                  class="input input-bordered"
                  placeholder="e.g., Material"
                  required
                />
              </div>

              <%!-- Key --%>
              <div class="form-control">
                <label class="label"><span class="label-text">Key</span></label>
                <input
                  type="text"
                  name="option[key]"
                  value={@form_data.key}
                  class="input input-bordered font-mono"
                  placeholder="Auto-generated from label"
                  disabled={@editing_option != nil}
                />
                <label class="label">
                  <span class="label-text-alt text-base-content/60">
                    Lowercase with underscores, auto-generated from label
                  </span>
                </label>
              </div>

              <%!-- Type --%>
              <div class="form-control">
                <label class="label"><span class="label-text">Type *</span></label>
                <select name="option[type]" class="select select-bordered">
                  <%= for type <- @supported_types do %>
                    <option value={type} selected={@form_data.type == type}>
                      {type}
                    </option>
                  <% end %>
                </select>
              </div>

              <%!-- Options (for select/multiselect) --%>
              <%= if @form_data.type in ["select", "multiselect"] do %>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Options *</span>
                    <button
                      type="button"
                      phx-click="add_option"
                      class="btn btn-ghost btn-xs"
                    >
                      <.icon name="hero-plus" class="w-4 h-4" /> Add
                    </button>
                  </label>
                  <div class="space-y-2">
                    <%= for {opt, idx} <- Enum.with_index(@form_data.options) do %>
                      <div class="flex gap-2">
                        <input
                          type="text"
                          name={"option[options][#{idx}]"}
                          value={opt}
                          class="input input-bordered input-sm flex-1"
                          placeholder="Option value"
                        />
                        <button
                          type="button"
                          phx-click="remove_option"
                          phx-value-index={idx}
                          class="btn btn-ghost btn-sm text-error"
                        >
                          <.icon name="hero-x-mark" class="w-4 h-4" />
                        </button>
                      </div>
                    <% end %>
                    <%= if @form_data.options == [] do %>
                      <p class="text-sm text-warning">Add at least one option</p>
                    <% end %>
                  </div>
                </div>

                <%!-- Affects Price Toggle --%>
                <div class="form-control">
                  <label class="label cursor-pointer justify-start gap-3">
                    <input
                      type="checkbox"
                      name="option[affects_price]"
                      value="true"
                      checked={@form_data.affects_price}
                      phx-click="toggle_affects_price"
                      class="checkbox checkbox-primary"
                    />
                    <span class="label-text">Affects Price</span>
                  </label>
                  <label class="label pt-0">
                    <span class="label-text-alt text-base-content/60">
                      Enable to add price modifiers for each option
                    </span>
                  </label>
                </div>

                <%!-- Modifier Type and Price Modifiers (when affects_price is true) --%>
                <%= if @form_data.affects_price and @form_data.options != [] do %>
                  <%!-- Modifier Type Selector --%>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">Modifier Type</span>
                    </label>
                    <div class="flex flex-wrap gap-4">
                      <label class="label cursor-pointer gap-2">
                        <input
                          type="radio"
                          name="option[modifier_type]"
                          value="fixed"
                          checked={@form_data.modifier_type != "percent"}
                          phx-click="set_modifier_type"
                          phx-value-type="fixed"
                          class="radio radio-primary"
                        />
                        <span class="label-text">Fixed (+10)</span>
                      </label>
                      <label class="label cursor-pointer gap-2">
                        <input
                          type="radio"
                          name="option[modifier_type]"
                          value="percent"
                          checked={@form_data.modifier_type == "percent"}
                          phx-click="set_modifier_type"
                          phx-value-type="percent"
                          class="radio radio-primary"
                        />
                        <span class="label-text">Percent (+20%)</span>
                      </label>
                    </div>
                  </div>

                  <%!-- Price Modifiers --%>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">Price Modifiers (Default Values)</span>
                    </label>
                    <div class="p-4 bg-base-200 rounded-lg space-y-3">
                      <p class="text-sm text-base-content/70 mb-3">
                        <%= if @form_data.modifier_type == "percent" do %>
                          Set percentage adjustment for each option (use 0 for no change)
                        <% else %>
                          Set price adjustment for each option (use 0 for no change)
                        <% end %>
                      </p>
                      <%= for opt <- @form_data.options do %>
                        <div class="flex items-center gap-3">
                          <span class="w-32 font-medium truncate" title={opt}>{opt}</span>
                          <span class="text-base-content/60">+</span>
                          <div class="join">
                            <input
                              type="number"
                              step="0.01"
                              min="0"
                              name={"option[price_modifiers][#{opt}]"}
                              value={Map.get(@form_data.price_modifiers, opt, "0")}
                              class="input input-sm input-bordered join-item w-24"
                              placeholder="0"
                            />
                            <%= if @form_data.modifier_type == "percent" do %>
                              <span class="join-item btn btn-sm btn-disabled">%</span>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>

                  <%!-- Allow Override Toggle --%>
                  <div class="form-control mt-4">
                    <label class="label cursor-pointer justify-start gap-3">
                      <input type="hidden" name="option[allow_override]" value="false" />
                      <input
                        type="checkbox"
                        name="option[allow_override]"
                        value="true"
                        checked={@form_data.allow_override}
                        phx-click="toggle_allow_override"
                        class="checkbox checkbox-primary"
                      />
                      <div>
                        <span class="label-text font-medium">Allow Override Per-Product</span>
                        <p class="text-xs text-base-content/60">
                          Enable editing price modifiers for each individual product
                        </p>
                      </div>
                    </label>
                  </div>
                <% end %>
              <% end %>

              <%!-- Warning for non-select types with affects_price --%>
              <%= if @form_data.affects_price && @form_data.type not in ["select", "multiselect"] do %>
                <div class="alert alert-warning">
                  <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                  <span>Price modifiers only work with Select or Multiselect types</span>
                </div>
              <% end %>

              <%!-- Unit --%>
              <div class="form-control">
                <label class="label"><span class="label-text">Unit (optional)</span></label>
                <input
                  type="text"
                  name="option[unit]"
                  value={@form_data.unit}
                  class="input input-bordered input-sm w-32"
                  placeholder="e.g., cm, kg"
                />
              </div>

              <%!-- Required --%>
              <div class="form-control">
                <label class="label cursor-pointer justify-start gap-3">
                  <input
                    type="checkbox"
                    name="option[required]"
                    value="true"
                    checked={@form_data.required}
                    class="checkbox checkbox-primary"
                  />
                  <span class="label-text">Required field</span>
                </label>
              </div>

              <%!-- Actions --%>
              <div class="modal-action">
                <button type="button" phx-click="close_modal" class="btn btn-ghost">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">
                  {if @editing_option, do: "Update", else: "Create"}
                </button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_modal"></div>
        </div>
      <% end %>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  # Private helpers

  defp initial_form_data do
    %{
      key: "",
      label: "",
      type: "text",
      options: [],
      required: false,
      unit: "",
      affects_price: false,
      modifier_type: "fixed",
      price_modifiers: %{},
      allow_override: false,
      enabled: true
    }
  end

  defp slugify_key(""), do: ""

  defp slugify_key(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.replace(~r/\s+/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp parse_form_params(params) do
    options = parse_options(params["options"])

    %{
      key: params["key"] || "",
      label: params["label"] || "",
      type: params["type"] || "text",
      options: options,
      required: params["required"] == "true",
      unit: params["unit"] || "",
      affects_price: params["affects_price"] == "true",
      modifier_type: params["modifier_type"] || "fixed",
      price_modifiers: parse_price_modifiers(params["price_modifiers"], options),
      allow_override: params["allow_override"] == "true"
    }
  end

  defp build_option(form_data) do
    key = if form_data.key == "", do: slugify_key(form_data.label), else: form_data.key

    %{
      "key" => key,
      "label" => form_data.label,
      "type" => form_data.type,
      "required" => form_data.required
    }
    |> maybe_put_options(form_data)
    |> maybe_put_unit(form_data)
    |> maybe_put_price_modifiers(form_data)
  end

  defp maybe_put_options(opt, %{type: type, options: options})
       when type in ["select", "multiselect"],
       do: Map.put(opt, "options", options)

  defp maybe_put_options(opt, _), do: opt

  defp maybe_put_unit(opt, %{unit: ""}), do: opt
  defp maybe_put_unit(opt, %{unit: unit}), do: Map.put(opt, "unit", unit)

  defp maybe_put_price_modifiers(
         opt,
         %{
           type: type,
           affects_price: true,
           modifier_type: modifier_type,
           price_modifiers: mods,
           allow_override: allow_override
         }
       )
       when type in ["select", "multiselect"] do
    opt
    |> Map.put("affects_price", true)
    |> Map.put("modifier_type", modifier_type)
    |> Map.put("price_modifiers", mods)
    |> Map.put("allow_override", allow_override)
  end

  defp maybe_put_price_modifiers(opt, _), do: Map.put(opt, "affects_price", false)

  defp parse_options(nil), do: []

  defp parse_options(options) when is_map(options) do
    options
    # Filter out Phoenix LiveView's hidden _unused_ fields
    |> Enum.reject(fn {k, _v} -> String.starts_with?(k, "_unused") end)
    |> Enum.sort_by(fn {k, _v} ->
      case Integer.parse(k) do
        {num, ""} -> num
        _ -> 0
      end
    end)
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_options(options) when is_list(options), do: options
  defp parse_options(_), do: []

  defp parse_price_modifiers(nil, _options), do: %{}

  defp parse_price_modifiers(modifiers, options) when is_map(modifiers) do
    # Only keep modifiers for valid options, with valid decimal values
    Enum.reduce(options, %{}, fn opt, acc ->
      value = Map.get(modifiers, opt, "0")
      # Normalize the value to a valid decimal string
      normalized = normalize_price_modifier(value)
      Map.put(acc, opt, normalized)
    end)
  end

  defp parse_price_modifiers(_, _), do: %{}

  defp normalize_price_modifier(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> Decimal.to_string(decimal)
      _ -> "0"
    end
  end

  defp normalize_price_modifier(_), do: "0"

  defp format_options_with_modifiers(%{
         "affects_price" => true,
         "options" => options,
         "modifier_type" => modifier_type,
         "price_modifiers" => modifiers
       })
       when is_list(options) and is_map(modifiers) do
    suffix = if modifier_type == "percent", do: "%", else: ""

    Enum.map_join(options, ", ", fn opt ->
      case Map.get(modifiers, opt) do
        nil -> opt
        "0" -> opt
        mod -> "#{opt} (+#{mod}#{suffix})"
      end
    end)
  end

  defp format_options_with_modifiers(%{
         "affects_price" => true,
         "options" => options,
         "price_modifiers" => modifiers
       })
       when is_list(options) and is_map(modifiers) do
    # Default to fixed for backward compatibility
    Enum.map_join(options, ", ", fn opt ->
      case Map.get(modifiers, opt) do
        nil -> opt
        "0" -> opt
        mod -> "#{opt} (+#{mod})"
      end
    end)
  end

  defp format_options_with_modifiers(%{"options" => options}) when is_list(options) do
    Enum.join(options, ", ")
  end

  defp format_options_with_modifiers(_), do: ""
end
