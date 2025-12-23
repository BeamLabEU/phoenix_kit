defmodule PhoenixKitWeb.Live.Users.UserDetails do
  @moduledoc """
  LiveView for displaying detailed user information.

  Displays user profile information in a tabbed interface with:
  - Profile tab: Basic info, status, roles, registration details

  Future tabs can be added for sessions, activity, connections, etc.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.CustomFields
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => user_id}, _session, socket) do
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    user_id_int =
      case Integer.parse(user_id) do
        {id, _} -> id
        :error -> nil
      end

    user = if user_id_int, do: Auth.get_user_with_roles(user_id_int), else: nil

    case user do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("User not found"))
         |> push_navigate(to: Routes.path("/admin/users"))}

      user ->
        custom_field_definitions = CustomFields.list_field_definitions()

        socket =
          socket
          |> assign(:user, user)
          |> assign(:page_title, user_display_name(user))
          |> assign(:project_title, project_title)
          |> assign(:active_tab, "profile")
          |> assign(:custom_field_definitions, custom_field_definitions)
          |> assign(:show_delete_modal, false)

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("show_delete_modal", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, true)}
  end

  @impl true
  def handle_event("hide_delete_modal", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, false)}
  end

  @impl true
  def handle_event("delete_user", _params, socket) do
    # User deletion not yet implemented in Auth API
    {:noreply,
     socket
     |> assign(:show_delete_modal, false)
     |> put_flash(:error, gettext("User deletion is not yet implemented"))}
  end

  defp user_display_name(user) do
    cond do
      user.first_name && user.last_name ->
        "#{user.first_name} #{user.last_name}"

      user.first_name ->
        user.first_name

      user.username ->
        user.username

      true ->
        user.email
    end
  end

  defp format_location(user) do
    [user.registration_city, user.registration_region, user.registration_country]
    |> Enum.filter(&(&1 && &1 != ""))
    |> Enum.join(", ")
    |> case do
      "" -> nil
      location -> location
    end
  end

  defp format_timezone(nil), do: "Not set"

  defp format_timezone(offset) when is_binary(offset) do
    case Integer.parse(offset) do
      {num, _} -> format_timezone_offset(num)
      :error -> offset
    end
  end

  defp format_timezone(offset) when is_integer(offset), do: format_timezone_offset(offset)

  defp format_timezone_offset(offset) do
    sign = if offset >= 0, do: "+", else: ""
    "UTC#{sign}#{offset}"
  end

  defp get_custom_field_value(user, field_key) do
    case user.custom_fields do
      nil -> nil
      fields -> Map.get(fields, field_key)
    end
  end

  defp format_custom_field_value(nil, _type), do: "-"
  defp format_custom_field_value("", _type), do: "-"

  defp format_custom_field_value(value, "boolean") do
    case value do
      true -> gettext("Yes")
      "true" -> gettext("Yes")
      false -> gettext("No")
      "false" -> gettext("No")
      _ -> to_string(value)
    end
  end

  defp format_custom_field_value(value, _type), do: to_string(value)
end
