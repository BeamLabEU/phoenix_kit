defmodule PhoenixKitWeb.Components.Core.UserInfo do
  @moduledoc """
  Provides user information display components.

  These components handle user-related data display including roles,
  statistics, avatars, and user counts. All components are designed to work
  with PhoenixKit's user and role system.
  """

  use Phoenix.Component
  alias PhoenixKit.Users.Role

  @doc """
  Displays user avatar with fallback to initials.

  Shows the user's avatar image if available (from custom_fields["avatar_file_id"]),
  otherwise displays the first letter of their email as a placeholder.

  ## Attributes
  - `user` - User struct with email and optional custom_fields
  - `size` - Avatar size: "xs" (w-6), "sm" (w-8), "md" (w-10), "lg" (w-12). Defaults to "sm"
  - `class` - Additional CSS classes

  ## Examples

      <.user_avatar user={user} />
      <.user_avatar user={user} size="lg" />
      <.user_avatar user={user} size="xs" class="ring ring-primary" />
  """
  attr :user, :map, required: true
  attr :size, :string, default: "sm"
  attr :class, :string, default: ""

  def user_avatar(assigns) do
    avatar_file_id = get_avatar_file_id(assigns.user)

    size_classes =
      case assigns.size do
        "xs" -> "w-6 h-6 text-[10px]"
        "sm" -> "w-8 h-8 text-xs"
        "md" -> "w-10 h-10 text-sm"
        "lg" -> "w-12 h-12 text-base"
        _ -> "w-8 h-8 text-xs"
      end

    storage_size =
      case assigns.size do
        "xs" -> "small"
        "sm" -> "small"
        "md" -> "medium"
        "lg" -> "medium"
        _ -> "small"
      end

    assigns =
      assigns
      |> assign(:avatar_file_id, avatar_file_id)
      |> assign(:size_classes, size_classes)
      |> assign(:storage_size, storage_size)
      |> assign(:initial, get_user_initial(assigns.user))

    ~H"""
    <div class={["avatar", if(@avatar_file_id, do: "", else: "placeholder")]}>
      <div class={[
        "bg-neutral text-neutral-content rounded-full overflow-hidden",
        @size_classes,
        @class
      ]}>
        <%= if @avatar_file_id do %>
          <% avatar_url = PhoenixKit.Storage.URLSigner.signed_url(@avatar_file_id, @storage_size) %>
          <img
            src={avatar_url}
            alt="Avatar"
            class="w-full h-full object-cover"
            onerror="this.style.display='none'; this.nextElementSibling.style.display='flex';"
          />
          <span class="hidden w-full h-full flex items-center justify-center">
            {@initial}
          </span>
        <% else %>
          <span>{@initial}</span>
        <% end %>
      </div>
    </div>
    """
  end

  defp get_avatar_file_id(nil), do: nil

  defp get_avatar_file_id(%{custom_fields: %{"avatar_file_id" => file_id}})
       when is_binary(file_id),
       do: file_id

  defp get_avatar_file_id(_user), do: nil

  defp get_user_initial(nil), do: "?"
  defp get_user_initial(%{email: nil}), do: "?"
  defp get_user_initial(%{email: ""}), do: "?"

  defp get_user_initial(%{email: email}) when is_binary(email),
    do: String.first(email) |> String.upcase()

  defp get_user_initial(_), do: "?"

  @doc """
  Displays user's primary role name.

  The primary role is determined as the first role in the user's roles list.
  If the user has no roles, displays "No role".

  ## Attributes
  - `user` - User struct with preloaded roles
  - `class` - CSS classes

  ## Examples

      <.primary_role user={user} />
      <.primary_role user={user} class="font-semibold" />
  """
  attr :user, :map, required: true
  attr :class, :string, default: ""

  def primary_role(assigns) do
    ~H"""
    <span class={@class}>
      {get_primary_role_name(@user)}
    </span>
    """
  end

  @doc """
  Displays users count for a specific role.

  Retrieves the count from role statistics map and displays it.
  If no count is found for the role, displays 0.

  ## Attributes
  - `role` - Role struct with id
  - `stats` - Map with role statistics (role_id => count)

  ## Examples

      <.users_count role={role} stats={@role_stats} />
      <.users_count role={role} stats={@role_stats} />
  """
  attr :role, :map, required: true
  attr :stats, :map, required: true

  def users_count(assigns) do
    ~H"""
    <span class="font-medium">
      {Map.get(@stats, @role.id, 0)}
    </span>
    """
  end

  # Private helpers

  defp get_primary_role_name(user) do
    case user.roles do
      [] -> "No role"
      [%Role{name: name} | _] -> name
      _ -> "No role"
    end
  end
end
