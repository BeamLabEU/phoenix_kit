defmodule PhoenixKitWeb.Live.Users.Media do
  @moduledoc """
  Media management LiveView — thin wrapper around `MediaBrowser` LiveComponent.

  This LiveView owns the page layout and assigns required by
  `LayoutWrapper.app_layout`. All media browser state and logic live in
  `PhoenixKitWeb.Components.MediaBrowser`.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale]

    settings =
      Settings.get_settings_cached(
        ["project_title"],
        %{"project_title" => PhoenixKit.Config.get(:project_title, "PhoenixKit")}
      )

    socket =
      socket
      |> assign(:page_title, "Media")
      |> assign(:project_title, settings["project_title"])
      |> assign(:current_locale, locale)
      |> assign(:url_path, Routes.path("/admin/media"))

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    if connected?(socket) do
      folder = params["folder"]
      q = params["q"] || ""

      page =
        case Integer.parse(params["page"] || "1") do
          {n, _} when n > 0 -> n
          _ -> 1
        end

      filter_orphaned = params["orphaned"] == "1"
      view = params["view"]

      send_update(PhoenixKitWeb.Components.MediaBrowser,
        id: "media-browser",
        nav_params: %{
          folder: folder,
          q: q,
          page: page,
          filter_orphaned: filter_orphaned,
          view: view
        }
      )
    end

    {:noreply, socket}
  end

  def handle_info(
        {PhoenixKitWeb.Components.MediaBrowser, "media-browser", {:navigate, params}},
        socket
      ) do
    folder = params[:folder]
    q = params[:q] || ""
    page = params[:page] || 1
    filter_orphaned = params[:filter_orphaned] || false
    view = params[:view]
    base = Routes.path("/admin/media")

    qs =
      %{}
      |> then(&if folder, do: Map.put(&1, "folder", folder), else: &1)
      |> then(&if q != "", do: Map.put(&1, "q", q), else: &1)
      |> then(&if page > 1, do: Map.put(&1, "page", page), else: &1)
      |> then(&if filter_orphaned, do: Map.put(&1, "orphaned", "1"), else: &1)
      |> then(&if view == "all", do: Map.put(&1, "view", "all"), else: &1)

    url = if qs == %{}, do: base, else: base <> "?" <> URI.encode_query(qs)
    {:noreply, push_patch(socket, to: url)}
  end
end
