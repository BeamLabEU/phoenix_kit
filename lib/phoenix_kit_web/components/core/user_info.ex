defmodule PhoenixKitWeb.Components.Core.UserInfo do
  @moduledoc """
  Provides user information display components.

  These components handle user-related data display including roles,
  statistics, and user counts. All components are designed to work
  with PhoenixKit's user and role system.
  """

  use Phoenix.Component
  alias PhoenixKit.Users.Role

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
