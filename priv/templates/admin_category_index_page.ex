defmodule <%= @web_module_prefix %>.PhoenixKit.Live.Admin.<%= @category %>.Index do
  @moduledoc """
  Index page for the <%= @category %> admin category.
  """

  use <%= @web_module_prefix %>, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, gettext("<%= @category %>"))
      |> assign(:url_path, "<%= @url %>")

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <.flash_messages flash={@flash} />

        <div class="bg-base-100 shadow-sm rounded-lg p-6">
          <div class="prose prose-sm dark:prose-invert max-w-none">
            <h1 class="text-2xl font-bold mb-6">{@page_title}</h1>
            <p>
              This is the index page for the {@page_title} section.
              Navigate to the subpages using the sidebar menu.
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
