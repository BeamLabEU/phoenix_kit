defmodule <%= @web_module_prefix %>.PhoenixKit.Admin.<%= @category %>.<%= @page_name %> do
  @moduledoc """
  Admin LiveView for <%= @page_title %> in <%= @category %> category.
  """

  use <%= @web_module_prefix %>, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, gettext("<%= @page_title %>"))
      |> assign(:url_path, "<%= @url %>")

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <div class="max-w-7xl px-4 sm:px-6 lg:px-8 py-8">
        <.flash_messages flash={@flash} />

        <div class="bg-base-100 shadow-sm rounded-lg p-6">
          <div class="prose prose-sm dark:prose-invert max-w-none">
            <h1 class="text-2xl font-bold mb-6">{@page_title}</h1>
            <p>
              This is a hello world template for your {@page_title} administration page.
              You can customize this page by modifying the LiveView module.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp flash_messages(assigns) do
    ~H"""
    <div :if={@flash[:info]} class="alert alert-info mb-4" role="alert">
      {@flash[:info]}
    </div>
    <div :if={@flash[:error]} class="alert alert-error mb-4" role="alert">
      {@flash[:error]}
    </div>
    """
  end
end
