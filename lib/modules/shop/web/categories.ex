defmodule PhoenixKit.Modules.Shop.Web.Categories do
  @moduledoc """
  Categories list LiveView for Shop module.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    categories = Shop.list_categories(preload: [:parent])

    socket =
      socket
      |> assign(:page_title, "Categories")
      |> assign(:categories, categories)

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
        <%!-- Header (centered pattern) --%>
        <header class="w-full relative mb-6">
          <.link
            navigate={Routes.path("/admin/shop")}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
          </.link>
          <div class="text-center pt-10 sm:pt-0">
            <h1 class="text-4xl font-bold text-base-content mb-3">Categories</h1>
            <p class="text-lg text-base-content/70">{length(@categories)} categories</p>
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
                  <th>Position</th>
                  <th class="text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= if Enum.empty?(@categories) do %>
                  <tr>
                    <td colspan="5" class="text-center py-12 text-base-content/50">
                      <.icon name="hero-folder" class="w-12 h-12 mx-auto mb-3 opacity-50" />
                      <p class="text-lg">No categories yet</p>
                      <p class="text-sm">Create your first category to organize products</p>
                    </td>
                  </tr>
                <% else %>
                  <%= for category <- @categories do %>
                    <tr class="hover">
                      <td>
                        <div class="flex items-center gap-3">
                          <div class="avatar placeholder">
                            <div class="bg-base-300 text-base-content/50 w-10 h-10 rounded">
                              <%= if category.image_url do %>
                                <img src={category.image_url} alt={category.name} />
                              <% else %>
                                <.icon name="hero-folder" class="w-5 h-5" />
                              <% end %>
                            </div>
                          </div>
                          <span class="font-medium">{category.name}</span>
                        </div>
                      </td>
                      <td class="text-base-content/60">{category.slug}</td>
                      <td>
                        <%= if category.parent do %>
                          <span class="badge badge-ghost">{category.parent.name}</span>
                        <% else %>
                          <span class="text-base-content/40">—</span>
                        <% end %>
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
end
