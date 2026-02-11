defmodule PhoenixKit.Modules.Comments.Web.Settings do
  @moduledoc """
  LiveView for Comments module settings management.

  Manages:
  - `comments_enabled` toggle
  - `comments_moderation` toggle
  - `comments_max_depth` input
  - `comments_max_length` input

  ## Route

  Mounted at `{prefix}/admin/settings/comments`.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings

  @impl true
  def mount(_params, _session, socket) do
    project_title = Settings.get_project_title()

    socket =
      socket
      |> assign(:page_title, "Comments Settings")
      |> assign(:project_title, project_title)
      |> assign(:saving, false)
      |> load_settings()

    {:ok, socket}
  end

  @impl true
  def handle_event("save", params, socket) do
    socket = assign(socket, :saving, true)
    settings = Map.get(params, "settings", %{})

    results =
      Enum.map(settings, fn {key, value} ->
        Settings.update_setting(key, value)
      end)

    socket =
      if Enum.all?(results, fn
           {:ok, _} -> true
           _ -> false
         end) do
        socket
        |> put_flash(:info, "Settings saved successfully")
        |> load_settings()
      else
        put_flash(socket, :error, "Failed to save some settings")
      end

    {:noreply, assign(socket, :saving, false)}
  end

  @impl true
  def handle_event("reset_defaults", _params, socket) do
    defaults = %{
      "comments_enabled" => "false",
      "comments_moderation" => "false",
      "comments_max_depth" => "10",
      "comments_max_length" => "10000"
    }

    Enum.each(defaults, fn {key, value} ->
      Settings.update_setting(key, value)
    end)

    {:noreply,
     socket
     |> put_flash(:info, "Settings reset to defaults")
     |> load_settings()}
  end

  defp load_settings(socket) do
    socket
    |> assign(:comments_enabled, Settings.get_setting("comments_enabled", "false"))
    |> assign(:comments_moderation, Settings.get_setting("comments_moderation", "false"))
    |> assign(:comments_max_depth, Settings.get_setting("comments_max_depth", "10"))
    |> assign(:comments_max_length, Settings.get_setting("comments_max_length", "10000"))
  end
end
