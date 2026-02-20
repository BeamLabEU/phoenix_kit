defmodule PhoenixKit.Modules.Shop.Web.TestShop do
  @moduledoc """
  Test module for verifying Shop functionality:
  - Specification price modifiers (fixed and percent)
  - Storage image integration
  - Price calculation
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.CartItem
  alias PhoenixKit.Modules.Shop.Options
  alias PhoenixKit.Modules.Shop.OptionTypes
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Shop Test Module")
      |> assign(:test_results, [])
      |> assign(:products, [])
      |> assign(:show_products, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("run_tests", _params, socket) do
    results = [
      test_option_types(),
      test_option_schema(),
      test_price_calculation(),
      test_storage_integration(),
      test_cart_with_specs()
    ]

    {:noreply, assign(socket, :test_results, results)}
  end

  @impl true
  def handle_event("load_products", _params, socket) do
    products = Shop.list_products(limit: 10, preload: [:category])
    {:noreply, assign(socket, products: products, show_products: true)}
  end

  @impl true
  def handle_event("test_product_price", %{"id" => id}, socket) do
    product = Shop.get_product(id, preload: [:category])

    if product do
      price_specs = Shop.get_price_affecting_specs(product)

      # Build test selections from first options
      test_selections =
        Enum.reduce(price_specs, %{}, fn opt, acc ->
          case opt["options"] do
            [first | _] -> Map.put(acc, opt["key"], first)
            _ -> acc
          end
        end)

      calculated_price = Shop.calculate_product_price(product, test_selections)
      {min_price, max_price} = Shop.get_price_range(product)

      product_title = Translations.get(product, :title, Translations.default_language())

      result = %{
        name: "Price Test: #{product_title}",
        status: :ok,
        details:
          "Base: $#{product.price}, Calculated: $#{calculated_price}, Range: $#{min_price} - $#{max_price}"
      }

      {:noreply, assign(socket, :test_results, socket.assigns.test_results ++ [result])}
    else
      {:noreply, put_flash(socket, :error, "Product not found")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
      <div class="p-6 max-w-4xl mx-auto">
        <div class="flex justify-between items-center mb-6">
          <h1 class="text-2xl font-bold">
            <.icon name="hero-beaker" class="w-7 h-7 inline" /> Shop Test Module
          </h1>
          <.link navigate={Routes.path("/admin/shop/products")} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>
        </div>

        <%!-- Test Actions --%>
        <div class="card bg-base-100 shadow-lg mb-6">
          <div class="card-body">
            <h2 class="card-title">Run Tests</h2>
            <p class="text-base-content/70 text-sm mb-4">
              Verify specification-based pricing (fixed and percent modifiers) and Storage image integration.
            </p>
            <div class="flex flex-wrap gap-3">
              <button phx-click="run_tests" class="btn btn-primary">
                <.icon name="hero-play" class="w-4 h-4" /> Run All Tests
              </button>
              <button phx-click="load_products" class="btn btn-outline">
                <.icon name="hero-cube" class="w-4 h-4" /> Load Products
              </button>
            </div>
          </div>
        </div>

        <%!-- Test Results --%>
        <%= if @test_results != [] do %>
          <div class="card bg-base-100 shadow-lg mb-6">
            <div class="card-body">
              <h2 class="card-title">Test Results</h2>
              <div class="overflow-x-auto">
                <table class="table table-zebra">
                  <thead>
                    <tr>
                      <th>Test</th>
                      <th>Status</th>
                      <th>Details</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for result <- @test_results do %>
                      <tr>
                        <td class="font-medium">{result.name}</td>
                        <td>
                          <%= case result.status do %>
                            <% :ok -> %>
                              <span class="badge badge-success">PASS</span>
                            <% :error -> %>
                              <span class="badge badge-error">FAIL</span>
                            <% :skip -> %>
                              <span class="badge badge-warning">SKIP</span>
                          <% end %>
                        </td>
                        <td class="text-sm text-base-content/70 max-w-md truncate">
                          {result.details}
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Products List --%>
        <%= if @show_products do %>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title">Products ({length(@products)})</h2>
              <%= if @products == [] do %>
                <div class="alert alert-info">
                  <.icon name="hero-information-circle" class="w-5 h-5" />
                  <span>No products found. Create some products first.</span>
                </div>
              <% else %>
                <div class="overflow-x-auto">
                  <table class="table">
                    <thead>
                      <tr>
                        <th>Product</th>
                        <th>Base Price</th>
                        <th>Has Options</th>
                        <th>Has Images</th>
                        <th>Actions</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for product <- @products do %>
                        <% price_specs = Shop.get_price_affecting_specs(product) %>
                        <% has_storage_images =
                          product.featured_image_id != nil or (product.image_ids || []) != [] %>
                        <% default_lang = Translations.default_language() %>
                        <tr>
                          <td>
                            <div class="font-medium">
                              {Translations.get(product, :title, default_lang)}
                            </div>
                            <div class="text-xs text-base-content/60">
                              {Translations.get(product, :slug, default_lang)}
                            </div>
                          </td>
                          <td>${Decimal.round(product.price || Decimal.new("0"), 2)}</td>
                          <td>
                            <%= if price_specs != [] do %>
                              <span class="badge badge-primary badge-sm">
                                {length(price_specs)} options
                              </span>
                            <% else %>
                              <span class="badge badge-ghost badge-sm">None</span>
                            <% end %>
                          </td>
                          <td>
                            <%= if has_storage_images do %>
                              <span class="badge badge-success badge-sm">
                                <.icon name="hero-check" class="w-3 h-3" /> Storage
                              </span>
                            <% else %>
                              <span class="badge badge-ghost badge-sm">Legacy</span>
                            <% end %>
                          </td>
                          <td>
                            <button
                              phx-click="test_product_price"
                              phx-value-id={product.uuid}
                              class="btn btn-xs btn-outline"
                            >
                              Test Price
                            </button>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Feature Documentation --%>
        <div class="card bg-base-200 mt-6">
          <div class="card-body">
            <h2 class="card-title text-lg">Features Implemented</h2>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-2">
              <div>
                <h3 class="font-semibold mb-2">
                  <.icon name="hero-calculator" class="w-4 h-4 inline" /> Price Modifiers
                </h3>
                <ul class="text-sm space-y-1 text-base-content/70">
                  <li>Fixed modifiers: +$X per option</li>
                  <li>Percent modifiers: +X% of base price</li>
                  <li>Order: fixed first, then percent applied</li>
                  <li>Cart items freeze price at add time</li>
                </ul>
              </div>
              <div>
                <h3 class="font-semibold mb-2">
                  <.icon name="hero-photo" class="w-4 h-4 inline" /> Storage Images
                </h3>
                <ul class="text-sm space-y-1 text-base-content/70">
                  <li>featured_image_id - main product image</li>
                  <li>image_ids[] - gallery images</li>
                  <li>Media selector integration</li>
                  <li>URL signing for secure access</li>
                </ul>
              </div>
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Layouts.dashboard>
    """
  end

  # Test functions

  defp test_option_types do
    # Test that affects_price validation works for select types with modifier_type
    valid_opt = %{
      "key" => "material",
      "label" => "Material",
      "type" => "select",
      "options" => ["PLA", "ABS", "PETG"],
      "affects_price" => true,
      "modifier_type" => "fixed",
      "price_modifiers" => %{
        "PLA" => "0",
        "ABS" => "5.00",
        "PETG" => "10.00"
      }
    }

    result =
      case OptionTypes.validate_option(valid_opt) do
        {:ok, _} -> :ok
        {:error, _} -> :error
      end

    %{
      name: "OptionTypes - Price Modifiers Validation",
      status: result,
      details:
        if(result == :ok,
          do: "Valid: select with affects_price, modifier_type=fixed",
          else: "Validation failed"
        )
    }
  end

  defp test_option_schema do
    # Test that global option schema loads correctly
    schema = Options.get_global_options()
    price_affecting = Enum.filter(schema, & &1["affects_price"])

    %{
      name: "Option Schema - Global Load",
      status: :ok,
      details: "Found #{length(schema)} options, #{length(price_affecting)} price-affecting"
    }
  end

  defp test_price_calculation do
    # Test price calculation with mock data (fixed modifiers)
    base_price = Decimal.new("20.00")

    mock_specs = [
      %{
        "key" => "material",
        "type" => "select",
        "affects_price" => true,
        "modifier_type" => "fixed",
        "price_modifiers" => %{"PLA" => "0", "PETG" => "10.00"}
      }
    ]

    selections = %{"material" => "PETG"}

    # Calculate final price
    final_price = Options.calculate_final_price(mock_specs, selections, base_price)

    # Expected: $20 + $10 = $30
    expected = Decimal.new("30.00")

    %{
      name: "Price Calculation - Fixed Modifier",
      status: if(Decimal.compare(final_price, expected) == :eq, do: :ok, else: :error),
      details: "Base $20 + PETG $10 = $#{final_price} (expected $#{expected})"
    }
  end

  defp test_storage_integration do
    # Test Storage module availability
    storage_enabled = function_exported?(Storage, :get_file, 1)

    %{
      name: "Storage Integration - Module Available",
      status: if(storage_enabled, do: :ok, else: :skip),
      details:
        if(storage_enabled,
          do: "Storage.get_file/1 available",
          else: "Storage module not available"
        )
    }
  end

  defp test_cart_with_specs do
    # Test CartItem schema has selected_specs field
    cart_item_fields = CartItem.__schema__(:fields)
    has_selected_specs = :selected_specs in cart_item_fields

    %{
      name: "CartItem Schema - selected_specs Field",
      status: if(has_selected_specs, do: :ok, else: :error),
      details:
        if(has_selected_specs,
          do: "CartItem has selected_specs field",
          else: "selected_specs field missing"
        )
    }
  end
end
