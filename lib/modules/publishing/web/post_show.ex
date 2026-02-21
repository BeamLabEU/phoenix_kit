defmodule PhoenixKit.Modules.Publishing.Web.PostShow do
  @moduledoc """
  Post overview page showing metadata, versions, languages, and actions.

  Accessible at `/admin/publishing/:group/:post_uuid`.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    group_slug = params["group"]
    post_uuid = params["post_uuid"]

    if connected?(socket) && group_slug do
      PublishingPubSub.subscribe_to_posts(group_slug)
    end

    date_time_settings =
      Settings.get_settings_cached(
        ["date_format", "time_format", "time_zone"],
        %{
          "date_format" => "Y-m-d",
          "time_format" => "H:i",
          "time_zone" => "0"
        }
      )

    socket =
      socket
      |> assign(:group_slug, group_slug)
      |> assign(:post_uuid, post_uuid)
      |> assign(:post, nil)
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> assign(:date_time_settings, date_time_settings)
      |> assign(:enabled_languages, Storage.enabled_language_codes())
      |> assign(:page_title, gettext("Post Overview"))

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"post_uuid" => post_uuid}, _uri, socket) do
    group_slug = socket.assigns.group_slug

    case Publishing.read_post_by_uuid(post_uuid) do
      {:ok, post} ->
        socket =
          socket
          |> assign(:post, post)
          |> assign(:post_uuid, post_uuid)
          |> assign(:page_title, post.metadata.title || gettext("Post Overview"))

        {:noreply, socket}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(to: Routes.path("/admin/publishing/#{group_slug}"))}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # PubSub handlers for live updates
  @impl true
  def handle_info({:post_updated, _group_slug, _post_slug}, socket) do
    # Reload post data
    case Publishing.read_post_by_uuid(socket.assigns.post_uuid) do
      {:ok, post} -> {:noreply, assign(socket, :post, post)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Helper functions available to template
  def format_datetime(post) do
    case {post[:date], post[:time]} do
      {%Date{} = date, %Time{} = time} ->
        {:ok, dt} = DateTime.new(date, time, "Etc/UTC")
        UtilsDate.format_datetime_with_user_format(dt)

      {%Date{} = date, _} ->
        UtilsDate.format_date_with_user_format(date)

      _ ->
        ""
    end
  end

  def version_status_badge_class("published"), do: "badge-success"
  def version_status_badge_class("draft"), do: "badge-warning"
  def version_status_badge_class("archived"), do: "badge-ghost"
  def version_status_badge_class(_), do: "badge-ghost"

  def language_status_color("published"), do: "bg-success"
  def language_status_color("draft"), do: "bg-warning"
  def language_status_color("archived"), do: "bg-base-content/20"
  def language_status_color(_), do: "bg-base-content/20"
end
