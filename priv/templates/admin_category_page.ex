  @moduledoc """
  Admin LiveView for <%= @page_title %> in <%= @category %> category.
  """

  use <%= @web_module_prefix %>, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, gettext("<%= @page_title %>"))
      |> assign(:current_path, Routes.path("<%= @url %>", locale: locale))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      current_path={@current_path}
      project_title={@project_title}
      current_locale={@current_locale}
    >
      <div class="bg-white dark:bg-gray-800 shadow-sm rounded-lg m-10 p-6">
        <div class="prose prose-sm dark:prose-invert max-w-none">
          <p>
            This is a hello world template for your {@page_title} administration page.
            You can customize this page by modifying the LiveView module.
          </p>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
