defmodule PhoenixKitWeb.Live.Modules.Billing.BillingProfiles do
  @moduledoc """
  Billing profiles list LiveView for the billing module.

  Provides billing profile management interface.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Billing
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @default_per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      socket =
        socket
        |> assign(:page_title, "Billing Profiles")
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/billing/profiles"))
        |> assign(:profiles, [])
        |> assign(:total_count, 0)
        |> assign(:loading, true)
        |> assign(:search, "")
        |> assign(:type_filter, "all")
        |> assign(:page, 1)
        |> assign(:per_page, @default_per_page)
        |> assign(:total_pages, 1)

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_profiles()

    {:noreply, socket}
  end

  defp apply_params(socket, params) do
    page = max(1, String.to_integer(params["page"] || "1"))
    search = params["search"] || ""
    type = params["type"] || "all"

    socket
    |> assign(:page, page)
    |> assign(:search, search)
    |> assign(:type_filter, type)
  end

  defp load_profiles(socket) do
    %{page: page, per_page: per_page, search: search, type_filter: type} = socket.assigns

    opts = [
      page: page,
      per_page: per_page,
      search: search,
      type: if(type == "all", do: nil, else: type),
      preload: [:user]
    ]

    {profiles, total_count} = Billing.list_billing_profiles_with_count(opts)
    total_pages = ceil(total_count / per_page)

    socket
    |> assign(:profiles, profiles)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, max(1, total_pages))
    |> assign(:loading, false)
  end

  @impl true
  def handle_event("filter", params, socket) do
    query_params =
      %{
        "search" => params["search"] || socket.assigns.search,
        "type" => params["type"] || socket.assigns.type_filter,
        "page" => "1"
      }
      |> Enum.reject(fn {_k, v} -> v == "" or v == "all" end)
      |> URI.encode_query()

    path =
      if query_params == "",
        do: Routes.path("/admin/billing/profiles"),
        else: Routes.path("/admin/billing/profiles?#{query_params}")

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: Routes.path("/admin/billing/profiles"))}
  end

  @impl true
  def handle_event("page_change", %{"page" => page}, socket) do
    query_params =
      %{
        "search" => socket.assigns.search,
        "type" => socket.assigns.type_filter,
        "page" => page
      }
      |> Enum.reject(fn {k, v} -> v == "" or v == "all" or (k == "page" and v == "1") end)
      |> URI.encode_query()

    path =
      if query_params == "",
        do: Routes.path("/admin/billing/profiles"),
        else: Routes.path("/admin/billing/profiles?#{query_params}")

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(:loading, true) |> load_profiles()}
  end
end
