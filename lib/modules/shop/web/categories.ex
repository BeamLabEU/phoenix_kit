defmodule PhoenixKit.Modules.Shop.Web.Categories do
  @moduledoc """
  Categories list LiveView for Shop module.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Modules.Shop.Category
  alias PhoenixKit.Modules.Shop.Translations
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    categories = Shop.list_categories(preload: [:parent])
    current_language = Translations.default_language()

    socket =
      socket
      |> assign(:page_title, "Categories")
      |> assign(:categories, categories)
      |> assign(:current_language, current_language)

    {:ok, socket}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    category = Shop.get_category!(id)

    case Shop.delete_category(category) do
      {:ok, _} ->
        categories = Shop.list_categories(preload: [:parent])

        {:noreply,
         socket
         |> assign(:categories, categories)
         |> put_flash(:info, "Category deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete category")}
    end
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
              navigate={Routes.path("/admin/shop")}
              class="btn btn-outline btn-primary btn-sm shrink-0"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
            </.link>
            <div class="flex-1 min-w-0">
              <h1 class="text-3xl font-bold text-base-content">Categories</h1>
              <p class="text-base-content/70 mt-1">{length(@categories)} categories</p>
            </div>
          </div>
        </header>

        <%!-- Controls Bar --%>
        <div class="bg-base-200 rounded-lg p-6 mb-6">
          <div class="flex flex-col lg:flex-row gap-4 justify-end">
            <%!-- Actions --%>
            <div class="w-full lg:w-auto">
              <.link navigate={Routes.path("/admin/shop/categories/new")} class="btn btn-primary">
                <.icon name="hero-plus" class="w-4 h-4 mr-2" /> Add Category
              </.link>
            </div>
          </div>
        </div>

        <%!-- Categories Table --%>
        <div class="card bg-base-100 shadow-xl overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Slug</th>
                  <th>Parent</th>
                  <th>Status</th>
                  <th>Position</th>
                  <th class="text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= if Enum.empty?(@categories) do %>
                  <tr>
                    <td colspan="6" class="text-center py-12 text-base-content/50">
                      <.icon name="hero-folder" class="w-12 h-12 mx-auto mb-3 opacity-50" />
                      <p class="text-lg">No categories yet</p>
                      <p class="text-sm">Create your first category to organize products</p>
                    </td>
                  </tr>
                <% else %>
                  <%= for category <- @categories do %>
                    <% cat_name = Translations.get(category, :name, @current_language) %>
                    <% cat_slug = Translations.get(category, :slug, @current_language) %>
                    <tr class="hover">
                      <td>
                        <div class="flex items-center gap-3">
                          <div class="avatar placeholder">
                            <div class="bg-base-300 text-base-content/50 w-10 h-10 rounded">
                              <%= if image_url = Category.get_image_url(category, size: "thumbnail") do %>
                                <img src={image_url} alt={cat_name} />
                              <% else %>
                                <.icon name="hero-folder" class="w-5 h-5" />
                              <% end %>
                            </div>
                          </div>
                          <span class="font-medium">{cat_name}</span>
                        </div>
                      </td>
                      <td class="text-base-content/60">{cat_slug}</td>
                      <td>
                        <%= if category.parent do %>
                          <span class="badge badge-ghost">
                            {Translations.get(category.parent, :name, @current_language)}
                          </span>
                        <% else %>
                          <span class="text-base-content/40">—</span>
                        <% end %>
                      </td>
                      <td>
                        <span class={status_badge_class(category.status)}>
                          {category.status || "active"}
                        </span>
                      </td>
                      <td>{category.position}</td>
                      <td class="text-right">
                        <div class="flex flex-wrap gap-1 justify-end">
                          <.link
                            navigate={Routes.path("/admin/shop/categories/#{category.id}/edit")}
                            class="btn btn-xs btn-outline btn-secondary"
                          >
                            <.icon name="hero-pencil" class="h-4 w-4" />
                          </.link>
                          <button
                            phx-click="delete"
                            phx-value-id={category.id}
                            data-confirm="Delete this category?"
                            class="btn btn-xs btn-outline btn-error"
                          >
                            <.icon name="hero-trash" class="h-4 w-4" />
                          </button>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp status_badge_class("active"), do: "badge badge-success"
  defp status_badge_class("unlisted"), do: "badge badge-warning"
  defp status_badge_class("hidden"), do: "badge badge-error"
  defp status_badge_class(_), do: "badge badge-success"
end
