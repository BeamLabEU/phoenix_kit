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
        allow_override: option["allow_override"] || false
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
      <div class="p-6 max-w-4xl mx-auto">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-3xl font-bold text-base-content">Product Options</h1>
            <p class="text-base-content/70 mt-1">
              Define global options that apply to all products
            </p>
          </div>

          <div class="flex gap-2">
            <.link navigate={Routes.path("/admin/shop/settings")} class="btn btn-ghost">
              <.icon name="hero-arrow-left" class="w-5 h-5 mr-2" /> Back
            </.link>
            <button type="button" phx-click="show_add_modal" class="btn btn-primary">
              <.icon name="hero-plus" class="w-5 h-5 mr-2" /> Add Option
            </button>
          </div>
        </div>

        <%!-- Info Alert --%>
        <div class="alert alert-info mb-6">
          <.icon name="hero-information-circle" class="w-6 h-6" />
          <div>
            <p class="font-medium">Global options apply to all products</p>
            <p class="text-sm">
              Categories can override these options or add their own specific ones.
              Options with "Affects Price" will modify the product price.
            </p>
          </div>
        </div>

        <%!-- Options List --%>
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body">
            <h2 class="card-title mb-4">
              <.icon name="hero-adjustments-horizontal" class="w-5 h-5" /> Global Options
            </h2>

            <%= if @options == [] do %>
              <div class="text-center py-12 text-base-content/60">
                <.icon name="hero-adjustments-horizontal" class="w-16 h-16 mx-auto mb-4 opacity-30" />
                <p class="text-lg">No options defined yet</p>
                <p class="text-sm">Add your first option to get started</p>
              </div>
            <% else %>
              <div class="flex flex-col gap-2">
                <%= for opt <- @options do %>
                  <div class="flex items-center p-4 bg-base-200 rounded-lg hover:bg-base-300 transition-colors">
                    <div class="flex-1 min-w-0">
                      <div class="flex items-center gap-2">
                        <span class="font-medium">{opt["label"]}</span>
                        <span class="badge badge-ghost badge-sm">{opt["type"]}</span>
                        <%= if opt["required"] do %>
                          <span class="badge badge-warning badge-sm">Required</span>
                        <% end %>
                        <%= if opt["unit"] do %>
                          <span class="badge badge-outline badge-sm">{opt["unit"]}</span>
                        <% end %>
                        <%= if opt["affects_price"] do %>
                          <span class="badge badge-success badge-sm">
                            Affects Price ({opt["modifier_type"] || "fixed"})
                          </span>
                          <%= if opt["allow_override"] do %>
                            <span class="badge badge-info badge-sm">Override</span>
                          <% end %>
                        <% end %>
                      </div>
                      <div class="text-sm text-base-content/60">
                        Key: <code class="bg-base-300 px-1 rounded">{opt["key"]}</code>
                        <%= if opt["options"] && opt["options"] != [] do %>
                          <span class="ml-2">
                            Options: {format_options_with_modifiers(opt)}
                          </span>
                        <% end %>
                      </div>
                    </div>

                    <div class="flex items-center gap-2">
                      <button
                        type="button"
                        phx-click="show_edit_modal"
                        phx-value-key={opt["key"]}
                        class="btn btn-ghost btn-sm"
                      >
                        <.icon name="hero-pencil" class="w-4 h-4" />
                      </button>
                      <button
                        type="button"
                        phx-click="delete_option"
                        phx-value-key={opt["key"]}
                        data-confirm="Delete this option?"
                        class="btn btn-ghost btn-sm text-error"
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

        <%!-- Supported Types Reference --%>
        <div class="card bg-base-200/50 mt-6">
          <div class="card-body">
            <h3 class="card-title text-sm">Supported Option Types</h3>
            <div class="flex flex-wrap gap-2">
              <span class="badge">text - Free text input</span>
              <span class="badge">number - Numeric input</span>
              <span class="badge">boolean - Yes/No checkbox</span>
              <span class="badge">select - Single choice dropdown</span>
              <span class="badge">multiselect - Multiple choice</span>
            </div>
            <div class="mt-4">
              <h4 class="font-medium text-sm mb-2">Price Modifier Types</h4>
              <div class="flex flex-wrap gap-2">
                <span class="badge badge-success">fixed - Add exact amount (+10)</span>
                <span class="badge badge-info">percent - Add percentage (+20%)</span>
              </div>
              <p class="text-xs text-base-content/60 mt-2">
                Enable "Allow Override" to edit values per-product
              </p>
            </div>
          </div>
        </div>
      </div>

      <%!-- Modal for Add/Edit Option --%>
      <%= if @show_modal do %>
        <div class="modal modal-open">
          <div class="modal-box max-w-lg">
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
                      <.icon name="hero-plus" class="w-4 h-4" /> Add Option
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
      allow_override: false
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
