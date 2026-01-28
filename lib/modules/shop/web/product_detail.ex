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
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    product = Shop.get_product!(id, preload: [:category])
    currency = Shop.get_default_currency()

    # Get price-affecting specs for admin view
    price_affecting_specs = Options.get_price_affecting_specs_for_product(product)

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

    {:ok, socket}
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case Shop.delete_product(socket.assigns.product) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Product deleted")
         |> push_navigate(to: Routes.path("/admin/shop/products"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete product")}
    end
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
        <%!-- Header --%>
        <header class="mb-6">
          <div class="flex items-start gap-4">
            <.link
              navigate={Routes.path("/admin/shop/products")}
              class="btn btn-outline btn-primary btn-sm shrink-0"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
            </.link>
            <div class="flex-1 min-w-0">
              <h1 class="text-3xl font-bold text-base-content">{@product_title}</h1>
              <p class="text-base-content/70 mt-1">{@product_slug}</p>
            </div>
          </div>
        </header>

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
                navigate={Routes.path("/admin/shop/products/#{@product.id}/edit")}
                class="btn btn-primary"
              >
                <.icon name="hero-pencil" class="w-4 h-4 mr-2" /> Edit
              </.link>
              <button
                phx-click="delete"
                data-confirm="Are you sure you want to delete this product?"
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
                <div class="aspect-video bg-base-200 rounded-lg overflow-hidden">
                  <%= if first_image(@product) do %>
                    <img
                      src={first_image(@product)}
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
                    <%= for image <- @product.images || [] do %>
                      <% url = image_url(image) %>
                      <%= if url do %>
                        <div class="w-16 h-16 rounded-lg overflow-hidden flex-shrink-0 bg-base-200">
                          <img src={url} alt="Thumbnail" class="w-full h-full object-cover" />
                        </div>
                      <% end %>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Details --%>
            <div class="card bg-base-100 shadow-xl">
              <div class="card-body">
                <h2 class="card-title">Product Details</h2>

                <%= if @product_description do %>
                  <p class="text-base-content/80">{@product_description}</p>
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

            <%!-- Option Values Section --%>
            <% option_values = @product.metadata["_option_values"] || %{} %>
            <%= if option_values != %{} do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body">
                  <h2 class="card-title">
                    <.icon name="hero-adjustments-horizontal" class="w-5 h-5" /> Available Options
                  </h2>
                  <div class="space-y-3">
                    <%= for {key, values} <- option_values do %>
                      <div class="flex flex-wrap items-center gap-2">
                        <span class="font-medium min-w-24">{String.capitalize(key)}:</span>
                        <%= for value <- values do %>
                          <span class="badge badge-outline">{value}</span>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>

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
                        {if @product.file_id, do: "Attached", else: "—"}
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
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
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

  # Image helpers
  # Storage-based images (new format)
  defp first_image(%{featured_image_id: id}) when is_binary(id) do
    get_storage_image_url(id, "small")
  end

  defp first_image(%{image_ids: [id | _]}) when is_binary(id) do
    get_storage_image_url(id, "small")
  end

  # Legacy URL-based images (Shopify imports)
  defp first_image(%{images: [%{"src" => src} | _]}), do: src
  defp first_image(%{images: [first | _]}) when is_binary(first), do: first
  defp first_image(_), do: nil

  # Get signed URL for Storage image
  defp get_storage_image_url(file_id, variant) do
    alias PhoenixKit.Modules.Storage
    alias PhoenixKit.Modules.Storage.URLSigner

    case Storage.get_file(file_id) do
      %{id: id} ->
        case Storage.get_file_instance_by_name(id, variant) do
          nil ->
            case Storage.get_file_instance_by_name(id, "original") do
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

  defp has_multiple_images?(%{images: [_, _ | _]}), do: true
  defp has_multiple_images?(_), do: false

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
          code = lang["code"]
          base = DialectMapper.extract_base(code)
          predefined = Languages.get_predefined_language(code)

          %{
            code: code,
            base: base,
            flag: (predefined && predefined.flag) || "🌐",
            name: lang["name"] || code
          }
        end)
    end
  end
end
