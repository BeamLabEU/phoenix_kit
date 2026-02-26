defmodule PhoenixKit.Modules.Shop.Web.ProductDetail do
  @moduledoc """
  Product detail view LiveView for Shop module.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Options
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    product = Shop.get_product!(id, preload: [:category])
    currency = Shop.get_default_currency()

    # Get price-affecting specs for admin view
    price_affecting_specs = Options.get_price_affecting_specs_for_product(product)

    # Get all selectable specs for admin view (includes all schema options, not filtered)
    selectable_specs = Options.get_all_selectable_specs_for_admin(product)

    {min_price, max_price} =
      Options.get_price_range(price_affecting_specs, product.price, product.metadata)

    default_lang = Translations.default_language()
    product_title = Translations.get(product, :title, default_lang)
    product_slug = Translations.get(product, :slug, default_lang)
    product_description = Translations.get(product, :description, default_lang)
    product_body_html = Translations.get(product, :body_html, default_lang)
    product_seo_title = Translations.get(product, :seo_title, default_lang)
    product_seo_description = Translations.get(product, :seo_description, default_lang)

    # Get enabled languages for preview switcher
    available_languages = get_available_languages()

    # Get all images for the gallery
    all_images = get_all_product_images(product)
    first_image_id = get_first_image_id(product)

    # Auto-select first value of each option for immediate add-to-cart
    # Uses selectable_specs to include both metadata and schema-defined options
    selected_specs =
      selectable_specs
      |> Enum.map(fn spec ->
        key = spec["key"]
        values = get_option_values(product, spec)
        {key, List.first(values)}
      end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.into(%{})

    socket =
      socket
      |> assign(:page_title, product_title)
      |> assign(:product, product)
      |> assign(:product_title, product_title)
      |> assign(:product_slug, product_slug)
      |> assign(:product_description, product_description)
      |> assign(:product_body_html, product_body_html)
      |> assign(:product_seo_title, product_seo_title)
      |> assign(:product_seo_description, product_seo_description)
      |> assign(:current_language, default_lang)
      |> assign(:available_languages, available_languages)
      |> assign(:currency, currency)
      |> assign(:price_affecting_specs, price_affecting_specs)
      |> assign(:min_price, min_price)
      |> assign(:max_price, max_price)
      |> assign(:all_images, all_images)
      |> assign(:selected_image_id, first_image_id)
      |> assign(:selectable_specs, selectable_specs)
      |> assign(:selected_specs, selected_specs)
      |> assign(:show_delete_modal, false)
      |> assign(:delete_media_checked, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    {:noreply, socket |> assign(:show_delete_modal, true) |> assign(:delete_media_checked, false)}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply,
     socket |> assign(:show_delete_modal, false) |> assign(:delete_media_checked, false)}
  end

  @impl true
  def handle_event("toggle_delete_media", _params, socket) do
    {:noreply, assign(socket, :delete_media_checked, !socket.assigns.delete_media_checked)}
  end

  @impl true
  def handle_event("delete", _params, socket) do
    product = socket.assigns.product

    file_uuids =
      if socket.assigns.delete_media_checked,
        do: Shop.collect_product_file_uuids(product),
        else: []

    case Shop.delete_product(product) do
      {:ok, _} ->
        if file_uuids != [], do: Storage.queue_file_cleanup(file_uuids)

        {:noreply,
         socket
         |> put_flash(:info, "Product deleted")
         |> push_navigate(to: Routes.path("/admin/shop/products"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete product")}
    end
  end

  @impl true
  def handle_event("select_image", %{"id" => image_id}, socket) do
    {:noreply, assign(socket, :selected_image_id, image_id)}
  end

  @impl true
  def handle_event("select_option", %{"key" => key, "value" => value}, socket) do
    product = socket.assigns.product
    selected_specs = Map.put(socket.assigns.selected_specs, key, value)

    # Check for image mapping - update selected_image_id if mapping exists
    selected_image_id =
      get_mapped_image_id(product, key, value, socket.assigns.selected_image_id)

    {:noreply,
     socket
     |> assign(:selected_specs, selected_specs)
     |> assign(:selected_image_id, selected_image_id)}
  end

  @impl true
  def handle_event("switch_preview_language", %{"language" => language}, socket) do
    product = socket.assigns.product

    # Update localized content for the selected language
    product_title = Translations.get(product, :title, language)
    product_slug = Translations.get(product, :slug, language)
    product_description = Translations.get(product, :description, language)
    product_body_html = Translations.get(product, :body_html, language)
    product_seo_title = Translations.get(product, :seo_title, language)
    product_seo_description = Translations.get(product, :seo_description, language)

    socket =
      socket
      |> assign(:current_language, language)
      |> assign(:product_title, product_title)
      |> assign(:product_slug, product_slug)
      |> assign(:product_description, product_description)
      |> assign(:product_body_html, product_body_html)
      |> assign(:product_seo_title, product_seo_title)
      |> assign(:product_seo_description, product_seo_description)

    {:noreply, socket}
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
        <.admin_page_header
          back={Routes.path("/admin/shop/products")}
          title={@product_title}
          subtitle={@product_slug}
        />

        <%!-- Controls Bar --%>
        <div class="bg-base-200 rounded-lg p-6 mb-6">
          <div class="flex flex-col lg:flex-row gap-4 items-center justify-between">
            <%!-- Language Preview Switcher --%>
            <div class="flex items-center gap-2">
              <span class="text-sm text-base-content/70">
                <.icon name="hero-eye" class="w-4 h-4 inline mr-1" /> Preview:
              </span>
              <div class="join">
                <%= for lang <- @available_languages do %>
                  <button
                    type="button"
                    phx-click="switch_preview_language"
                    phx-value-language={lang.code}
                    class={[
                      "join-item btn btn-sm",
                      if(lang.code == @current_language, do: "btn-primary", else: "btn-ghost")
                    ]}
                  >
                    <span class="text-base mr-1">{lang.flag}</span>
                    <span class="uppercase">{lang.base}</span>
                  </button>
                <% end %>
              </div>
            </div>

            <%!-- Action Buttons --%>
            <div class="flex gap-2">
              <.link
                navigate={Routes.path("/admin/shop/products/#{@product.uuid}/edit")}
                class="btn btn-primary"
              >
                <.icon name="hero-pencil" class="w-4 h-4 mr-2" /> Edit
              </.link>
              <button
                phx-click="confirm_delete"
                class="btn btn-outline btn-error"
              >
                <.icon name="hero-trash" class="w-4 h-4 mr-2" /> Delete
              </button>
            </div>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <%!-- Main Content --%>
          <div class="lg:col-span-2 space-y-6">
            <%!-- Product Image --%>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">Image</h2>
                <% selected_url = get_image_url_by_id(@product, @selected_image_id) %>
                <div class="aspect-video bg-base-200 rounded-lg overflow-hidden">
                  <%= if selected_url do %>
                    <img
                      src={selected_url}
                      alt={@product_title}
                      class="w-full h-full object-contain"
                    />
                  <% else %>
                    <div class="w-full h-full flex items-center justify-center">
                      <.icon name="hero-photo" class="w-16 h-16 opacity-30" />
                      <span class="ml-2 text-base-content/50">No image</span>
                    </div>
                  <% end %>
                </div>
                <%= if has_multiple_images?(@product) do %>
                  <div class="flex gap-2 mt-4 overflow-x-auto">
                    <%= for {image_id, url} <- @all_images do %>
                      <%= if url do %>
                        <button
                          type="button"
                          phx-click="select_image"
                          phx-value-id={image_id}
                          class={[
                            "w-16 h-16 rounded-lg overflow-hidden flex-shrink-0 bg-base-200 transition-all",
                            image_id == @selected_image_id && "ring-2 ring-primary ring-offset-2"
                          ]}
                        >
                          <img src={url} alt="Thumbnail" class="w-full h-full object-cover" />
                        </button>
                      <% end %>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Option Values Section --%>
            <% image_mappings = @product.metadata["_image_mappings"] || %{} %>
            <%= if @selectable_specs != [] do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body">
                  <h2 class="card-title">
                    <.icon name="hero-adjustments-horizontal" class="w-5 h-5" /> Available Options
                  </h2>
                  <div class="space-y-3">
                    <%= for attr <- @selectable_specs do %>
                      <% affects_price = attr["affects_price"] == true %>
                      <div class="flex flex-wrap items-center gap-2">
                        <span class="font-medium min-w-24">{attr["label"]}:</span>
                        <%= for value <- get_option_values(@product, attr) do %>
                          <% has_image = get_in(image_mappings, [attr["key"], value]) not in [nil, ""] %>
                          <% price_mod =
                            affects_price && get_price_modifier(@product, attr["key"], value) %>
                          <button
                            type="button"
                            phx-click="select_option"
                            phx-value-key={attr["key"]}
                            phx-value-value={value}
                            class={[
                              "badge cursor-pointer transition-all",
                              if(@selected_specs[attr["key"]] == value,
                                do: "badge-primary",
                                else: "badge-outline hover:badge-primary/30"
                              ),
                              (has_image || price_mod) && "gap-1"
                            ]}
                          >
                            <%= if has_image do %>
                              <.icon name="hero-photo" class="w-3 h-3" />
                            <% end %>
                            {value}
                            <%= if price_mod do %>
                              <span class="text-xs opacity-70">
                                {format_price_modifier(price_mod, @currency)}
                              </span>
                            <% end %>
                          </button>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>

            <%!-- Details --%>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">Product Details</h2>

                <%= if @product_description do %>
                  <.markdown
                    content={@product_description}
                    sanitize={false}
                    compact
                    class="text-base-content/80"
                  />
                <% end %>

                <div class="divider"></div>

                <div class="grid grid-cols-2 gap-4 text-sm">
                  <div>
                    <span class="text-base-content/60">Type:</span>
                    <span class="ml-2 font-medium capitalize">{@product.product_type}</span>
                  </div>
                  <div>
                    <span class="text-base-content/60">Vendor:</span>
                    <span class="ml-2 font-medium">{@product.vendor || "—"}</span>
                  </div>
                  <div>
                    <span class="text-base-content/60">Taxable:</span>
                    <span class="ml-2 font-medium">{if @product.taxable, do: "Yes", else: "No"}</span>
                  </div>
                  <div>
                    <span class="text-base-content/60">Weight:</span>
                    <span class="ml-2 font-medium">{@product.weight_grams || 0}g</span>
                  </div>
                  <div>
                    <span class="text-base-content/60">Requires Shipping:</span>
                    <span class="ml-2 font-medium">
                      {if @product.requires_shipping, do: "Yes", else: "No"}
                    </span>
                  </div>
                  <div>
                    <span class="text-base-content/60">Made to Order:</span>
                    <span class="ml-2 font-medium">
                      {if @product.made_to_order, do: "Yes", else: "No"}
                    </span>
                  </div>
                </div>

                <%!-- Tags --%>
                <%= if @product.tags && @product.tags != [] do %>
                  <div class="divider"></div>
                  <div>
                    <span class="text-base-content/60 text-sm">Tags:</span>
                    <div class="flex flex-wrap gap-1 mt-2">
                      <%= for tag <- @product.tags do %>
                        <span class="badge badge-outline badge-sm">{tag}</span>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <%!-- Body HTML --%>
                <%= if @product_body_html && @product_body_html != "" do %>
                  <div class="divider"></div>
                  <div>
                    <span class="text-base-content/60 text-sm">Full Description:</span>
                    <div class="prose prose-sm mt-2 max-w-none">
                      {Phoenix.HTML.raw(@product_body_html)}
                    </div>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Pricing --%>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <div class="flex items-center justify-between">
                  <h2 class="card-title">Pricing</h2>
                  <span class="badge badge-outline">{(@currency && @currency.code) || "—"}</span>
                </div>

                <div class="grid grid-cols-3 gap-4 mt-4">
                  <div class="stat p-0">
                    <div class="stat-title">Price</div>
                    <div class="stat-value text-2xl">
                      {format_price(@product.price, @currency)}
                    </div>
                  </div>

                  <%= if @product.compare_at_price do %>
                    <div class="stat p-0">
                      <div class="stat-title">Compare At</div>
                      <div class="stat-value text-2xl text-base-content/50 line-through">
                        {format_price(@product.compare_at_price, @currency)}
                      </div>
                    </div>
                  <% end %>

                  <%= if @product.cost_per_item do %>
                    <div class="stat p-0">
                      <div class="stat-title">Cost</div>
                      <div class="stat-value text-2xl text-base-content/70">
                        {format_price(@product.cost_per_item, @currency)}
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>

            <%!-- Price Modifiers Section (Admin Only) --%>
            <%= if @price_affecting_specs != [] do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body">
                  <h2 class="card-title">
                    <.icon name="hero-calculator" class="w-5 h-5" /> Price Calculation
                  </h2>

                  <div class="bg-base-200 rounded-lg p-4 text-sm space-y-3">
                    <%!-- Base Price --%>
                    <div class="flex justify-between">
                      <span class="text-base-content/70">Base Price</span>
                      <span class="font-medium">{format_price(@product.price, @currency)}</span>
                    </div>

                    <%!-- Options with modifiers --%>
                    <%= for spec <- @price_affecting_specs do %>
                      <div class="border-t border-base-300 pt-3">
                        <div class="flex justify-between items-center mb-2">
                          <span class="font-medium">{spec["label"]}</span>
                          <span class="badge badge-sm badge-ghost">
                            {spec["modifier_type"] || "fixed"}
                          </span>
                        </div>
                        <div class="flex flex-wrap gap-1">
                          <%= for {value, modifier} <- spec["price_modifiers"] || %{} do %>
                            <% mod_value = parse_modifier(modifier) %>
                            <span class={[
                              "badge badge-sm",
                              if(Decimal.compare(mod_value, Decimal.new("0")) == :gt,
                                do: "badge-success",
                                else: "badge-ghost"
                              )
                            ]}>
                              {value}
                              <%= if Decimal.compare(mod_value, Decimal.new("0")) != :eq do %>
                                <span class="ml-1 opacity-70">
                                  +{format_modifier(mod_value, spec["modifier_type"], @currency)}
                                </span>
                              <% end %>
                            </span>
                          <% end %>
                        </div>
                      </div>
                    <% end %>

                    <%!-- Price Range --%>
                    <div class="divider my-2"></div>
                    <div class="flex justify-between font-bold">
                      <span>Price Range</span>
                      <span class="text-primary">
                        <%= if Decimal.compare(@min_price, @max_price) == :eq do %>
                          {format_price(@min_price, @currency)}
                        <% else %>
                          {format_price(@min_price, @currency)} — {format_price(@max_price, @currency)}
                        <% end %>
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>

          <%!-- Sidebar --%>
          <div class="space-y-6">
            <%!-- Status --%>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">Status</h2>
                <div class="flex items-center gap-2">
                  <span class={status_badge_class(@product.status)}>
                    {String.capitalize(@product.status)}
                  </span>
                </div>
              </div>
            </div>

            <%!-- Category --%>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">Category</h2>
                <%= if @product.category do %>
                  <span class="badge badge-lg">
                    {Translations.get(@product.category, :name, @current_language)}
                  </span>
                <% else %>
                  <span class="text-base-content/50">No category</span>
                <% end %>
              </div>
            </div>

            <%!-- Digital Product --%>
            <%= if @product.product_type == "digital" do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body text-sm">
                  <h2 class="card-title">Digital Product</h2>
                  <div class="space-y-2 text-base-content/70">
                    <div>
                      <span>File:</span>
                      <span class="ml-2">
                        {if @product.file_uuid, do: "Attached", else: "—"}
                      </span>
                    </div>
                    <div>
                      <span>Download Limit:</span>
                      <span class="ml-2">{@product.download_limit || "Unlimited"}</span>
                    </div>
                    <div>
                      <span>Expiry:</span>
                      <span class="ml-2">
                        {if @product.download_expiry_days,
                          do: "#{@product.download_expiry_days} days",
                          else: "Never"}
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>

            <%!-- SEO --%>
            <%= if @product_seo_title || @product_seo_description do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body text-sm">
                  <h2 class="card-title">SEO</h2>
                  <div class="space-y-2">
                    <%= if @product_seo_title do %>
                      <div>
                        <span class="text-base-content/60">Title:</span>
                        <p class="font-medium">{@product_seo_title}</p>
                      </div>
                    <% end %>
                    <%= if @product_seo_description do %>
                      <div>
                        <span class="text-base-content/60">Description:</span>
                        <p class="text-base-content/70">{@product_seo_description}</p>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>

            <%!-- Timestamps --%>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body text-sm">
                <h2 class="card-title">Timestamps</h2>
                <div class="space-y-2 text-base-content/70">
                  <div>
                    <span>Created:</span>
                    <span class="ml-2">
                      {Calendar.strftime(@product.inserted_at, "%Y-%m-%d %H:%M")}
                    </span>
                  </div>
                  <div>
                    <span>Updated:</span>
                    <span class="ml-2">
                      {Calendar.strftime(@product.updated_at, "%Y-%m-%d %H:%M")}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
      <%!-- Delete Product Modal --%>
      <%= if @show_delete_modal do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg text-error mb-4">Delete Product</h3>
            <p class="mb-4">
              Are you sure you want to delete this product? This action cannot be undone.
            </p>
            <label class="label cursor-pointer justify-start gap-3">
              <input
                type="checkbox"
                class="checkbox checkbox-error"
                phx-click="toggle_delete_media"
                checked={@delete_media_checked}
              />
              <span class="label-text">Delete associated media files (orphaned only)</span>
            </label>
            <div class="modal-action">
              <button phx-click="cancel_delete" class="btn">Cancel</button>
              <button phx-click="delete" class="btn btn-error">
                <.icon name="hero-trash" class="w-4 h-4 mr-2" /> Delete
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="cancel_delete"></div>
        </div>
      <% end %>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp get_mapped_image_id(product, option_key, option_value, current_image_id) do
    case get_in(product.metadata || %{}, ["_image_mappings", option_key, option_value]) do
      nil -> current_image_id
      "" -> current_image_id
      "http" <> _rest -> current_image_id
      image_id -> image_id
    end
  end

  defp get_option_values(product, option) do
    key = option["key"]

    values =
      case product.metadata do
        %{"_option_values" => %{^key => vals}} when is_list(vals) and vals != [] ->
          vals

        _ ->
          option["options"] || []
      end

    # Apply stored order if exists
    stored_order = get_in(product.metadata, ["_option_value_order", key])

    if stored_order do
      # Filter to only include values that still exist
      ordered_existing = Enum.filter(stored_order, &(&1 in values))
      # Add any new values not in stored order at the end
      new_values = Enum.reject(values, &(&1 in stored_order))
      ordered_existing ++ new_values
    else
      values
    end
  end

  defp get_price_modifier(product, key, value) do
    case product.metadata do
      %{"_price_modifiers" => %{^key => modifiers}} when is_map(modifiers) ->
        case Map.get(modifiers, value) do
          mod when is_number(mod) -> Decimal.new("#{mod}")
          mod when is_binary(mod) -> Decimal.new(mod)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp format_price_modifier(nil, _currency), do: ""

  defp format_price_modifier(mod, currency) do
    cond do
      Decimal.compare(mod, 0) == :gt -> "+#{format_price(mod, currency)}"
      Decimal.compare(mod, 0) == :lt -> format_price(mod, currency)
      true -> ""
    end
  end

  defp status_badge_class("active"), do: "badge badge-success badge-lg"
  defp status_badge_class("draft"), do: "badge badge-warning badge-lg"
  defp status_badge_class("archived"), do: "badge badge-neutral badge-lg"
  defp status_badge_class(_), do: "badge badge-lg"

  defp format_price(nil, _currency), do: "—"

  defp format_price(price, %Currency{} = currency) do
    Currency.format_amount(price, currency)
  end

  defp format_price(price, nil) do
    "$#{Decimal.round(price, 2)}"
  end

  # Get signed URL for Storage image (skip URLs - they are legacy Shopify images)
  defp get_storage_image_url("http" <> _ = _url, _variant), do: nil

  defp get_storage_image_url(file_id, variant) do
    case Storage.get_file(file_id) do
      %{uuid: uuid} ->
        case Storage.get_file_instance_by_name(uuid, variant) do
          nil ->
            case Storage.get_file_instance_by_name(uuid, "original") do
              nil -> nil
              _instance -> URLSigner.signed_url(file_id, "original")
            end

          _instance ->
            URLSigner.signed_url(file_id, variant)
        end

      nil ->
        nil
    end
  end

  defp image_url(%{"src" => src}), do: src
  defp image_url(url) when is_binary(url), do: url
  defp image_url(_), do: nil

  # Check if product has multiple images (Storage format or legacy)
  defp has_multiple_images?(%{featured_image_uuid: id, image_ids: [_ | _]})
       when is_binary(id),
       do: true

  defp has_multiple_images?(%{image_ids: [_, _ | _]}), do: true
  defp has_multiple_images?(%{images: [_, _ | _]}), do: true
  defp has_multiple_images?(_), do: false

  # Get ID of the first image (for initial selection)
  defp get_first_image_id(%{featured_image_uuid: id}) when is_binary(id), do: id
  defp get_first_image_id(%{image_ids: [id | _]}) when is_binary(id), do: id
  defp get_first_image_id(%{images: [%{"src" => src} | _]}), do: src
  defp get_first_image_id(%{images: [url | _]}) when is_binary(url), do: url
  defp get_first_image_id(_), do: nil

  # Get image URL by ID (for selected image display)
  # Storage-based images: featured_image_uuid is a UUID string
  defp get_image_url_by_id(%{featured_image_uuid: id} = product, image_id)
       when is_binary(id) and is_binary(image_id) do
    cond do
      id == image_id -> get_storage_image_url(image_id, "small")
      image_id in (product.image_ids || []) -> get_storage_image_url(image_id, "small")
      true -> get_storage_image_url(image_id, "small")
    end
  end

  defp get_image_url_by_id(%{image_ids: [_ | _] = ids}, image_id)
       when is_binary(image_id) do
    if image_id in ids do
      get_storage_image_url(image_id, "small")
    else
      nil
    end
  end

  defp get_image_url_by_id(%{images: images}, image_id) when is_binary(image_id) do
    # For legacy images, image_id is the URL itself
    if Enum.any?(images, fn img -> image_url(img) == image_id end) do
      image_id
    else
      nil
    end
  end

  defp get_image_url_by_id(_, _), do: nil

  # Get all product images as list of {id, url} tuples (featured first, then gallery)
  defp get_all_product_images(%{featured_image_uuid: featured_id, image_ids: gallery_ids})
       when is_binary(featured_id) do
    # Combine featured + gallery, avoiding duplicates
    all_ids = [featured_id | Enum.reject(gallery_ids || [], &(&1 == featured_id))]

    Enum.map(all_ids, fn id ->
      url = get_storage_image_url(id, "thumbnail")
      {id, url}
    end)
    |> Enum.reject(fn {_, url} -> is_nil(url) end)
  end

  defp get_all_product_images(%{image_ids: [_ | _] = ids}) do
    Enum.map(ids, fn id ->
      url = get_storage_image_url(id, "thumbnail")
      {id, url}
    end)
    |> Enum.reject(fn {_, url} -> is_nil(url) end)
  end

  defp get_all_product_images(%{images: images}) when is_list(images) do
    # For legacy images, use URL as ID
    Enum.map(images, fn img ->
      url = image_url(img)
      {url, url}
    end)
    |> Enum.reject(fn {_, url} -> is_nil(url) end)
  end

  defp get_all_product_images(_), do: []

  # Price modifier helpers
  defp parse_modifier(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _ -> Decimal.new("0")
    end
  end

  defp parse_modifier(%{"value" => value}), do: parse_modifier(value)
  defp parse_modifier(_), do: Decimal.new("0")

  defp format_modifier(value, "percent", _currency) do
    "#{Decimal.round(value, 0)}%"
  end

  defp format_modifier(value, _type, %Currency{} = currency) do
    Currency.format_amount(value, currency)
  end

  defp format_modifier(value, _type, _currency) do
    "$#{Decimal.round(value, 2)}"
  end

  # Get available languages for preview switcher
  defp get_available_languages do
    case Languages.get_enabled_languages() do
      [] ->
        # Fallback to default language when no languages enabled
        [%{code: Translations.default_language(), base: "en", flag: "🇺🇸", name: "English"}]

      enabled ->
        Enum.map(enabled, fn lang ->
          code = lang.code
          base = DialectMapper.extract_base(code)
          predefined = Languages.get_predefined_language(code)

          %{
            code: code,
            base: base,
            flag: (predefined && predefined.flag) || "🌐",
            name: lang.name || code
          }
        end)
    end
  end
end
