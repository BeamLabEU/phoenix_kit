defmodule PhoenixKitWeb.Components.Core.UserInfo do
  @moduledoc """
  Provides user information display components.

  These components handle user-related data display including roles,
  statistics, avatars, and user counts. All components are designed to work
  with PhoenixKit's user and role system.
  """

  use Phoenix.Component

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Role

  # Gradient colors for avatar fallback (15 variants)
  @gradients [
    "from-red-400 to-pink-500",
    "from-orange-400 to-red-500",
    "from-amber-400 to-orange-500",
    "from-yellow-400 to-amber-500",
    "from-lime-400 to-green-500",
    "from-green-400 to-emerald-500",
    "from-emerald-400 to-teal-500",
    "from-teal-400 to-cyan-500",
    "from-cyan-400 to-sky-500",
    "from-sky-400 to-blue-500",
    "from-blue-400 to-indigo-500",
    "from-indigo-400 to-violet-500",
    "from-violet-400 to-purple-500",
    "from-purple-400 to-fuchsia-500",
    "from-fuchsia-400 to-pink-500"
  ]

  @doc """
  Displays user avatar with cascading fallback sources.

  Avatar sources are checked in priority order:
  1. Uploaded avatar (custom_fields["avatar_file_id"]) - PhoenixKit Storage
  2. OAuth avatar (custom_fields["oauth_avatar_url"]) - Google/GitHub/etc
  3. Gravatar - by email hash (with d=404 for fallback detection)
  4. Gradient initials - colored background based on email hash

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
    email = get_email(assigns.user)
    avatar_result = get_avatar_source(assigns.user, assigns.size)

    avatar_url =
      case avatar_result do
        {:storage, file_id, storage_size} ->
          URLSigner.signed_url(file_id, storage_size)

        {:url, url} ->
          url

        {:gravatar, url} ->
          url

        nil ->
          nil
      end

    size_classes = size_classes(assigns.size)
    gradient = gradient_for_email(email)
    initial = get_user_initial(assigns.user)

    assigns =
      assigns
      |> assign(:avatar_url, avatar_url)
      |> assign(:size_classes, size_classes)
      |> assign(:gradient, gradient)
      |> assign(:initial, initial)

    ~H"""
    <div class={["avatar", if(@avatar_url, do: "", else: "placeholder")]}>
      <div class={[
        "rounded-full overflow-hidden relative flex items-center justify-center",
        if(@avatar_url, do: "bg-neutral", else: ["bg-gradient-to-br", @gradient]),
        "text-white font-bold",
        @size_classes,
        @class
      ]}>
        <%= if @avatar_url do %>
          <%!-- Fallback initials (always rendered, shown when image fails) --%>
          <span
            class={[
              "absolute inset-0 flex items-center justify-center",
              "bg-gradient-to-br",
              @gradient
            ]}
            data-fallback="true"
          >
            {@initial}
          </span>
          <%!-- Image overlay (hides fallback when loaded successfully) --%>
          <img
            src={@avatar_url}
            alt="Avatar"
            class="absolute inset-0 w-full h-full object-cover"
            onerror="this.style.display='none';"
          />
        <% else %>
          <span>{@initial}</span>
        <% end %>
      </div>
    </div>
    """
  end

  # Avatar source resolution (cascading priority)
  defp get_avatar_source(user, size) do
    cond do
      # 1. Custom uploaded avatar (highest priority)
      avatar_file_id = get_avatar_file_id(user) ->
        {:storage, avatar_file_id, storage_size(size)}

      # 2. OAuth avatar (Google/GitHub/etc)
      oauth_url = get_oauth_avatar_url(user) ->
        {:url, oauth_url}

      # 3. Gravatar (will try to load, fallback on error)
      email = get_email(user) ->
        {:gravatar, gravatar_url(email, gravatar_pixel_size(size))}

      # 4. No avatar sources available
      true ->
        nil
    end
  end

  defp get_avatar_file_id(nil), do: nil

  defp get_avatar_file_id(%{custom_fields: %{"avatar_file_id" => file_id}})
       when is_binary(file_id) and file_id != "",
       do: file_id

  defp get_avatar_file_id(_user), do: nil

  defp get_oauth_avatar_url(nil), do: nil

  defp get_oauth_avatar_url(%{custom_fields: %{"oauth_avatar_url" => url}})
       when is_binary(url) and url != "",
       do: url

  defp get_oauth_avatar_url(_user), do: nil

  defp get_email(nil), do: nil
  defp get_email(%{email: email}) when is_binary(email) and email != "", do: email
  defp get_email(_), do: nil

  # Gravatar URL generation
  # Using d=blank returns a transparent image when no Gravatar exists,
  # allowing the fallback initials to show through
  defp gravatar_url(email, pixel_size) do
    hash =
      :crypto.hash(:md5, String.downcase(String.trim(email)))
      |> Base.encode16(case: :lower)

    "https://www.gravatar.com/avatar/#{hash}?s=#{pixel_size}&d=blank"
  end

  defp gravatar_pixel_size(size) do
    case size do
      "xs" -> 48
      "sm" -> 64
      "md" -> 80
      "lg" -> 96
      _ -> 64
    end
  end

  # Size classes for the avatar container
  defp size_classes(size) do
    case size do
      "xs" -> "w-6 h-6 text-[10px]"
      "sm" -> "w-8 h-8 text-xs"
      "md" -> "w-10 h-10 text-sm"
      "lg" -> "w-12 h-12 text-base"
      _ -> "w-8 h-8 text-xs"
    end
  end

  # Storage size for PhoenixKit Storage
  defp storage_size(size) do
    case size do
      "xs" -> "small"
      "sm" -> "small"
      "md" -> "medium"
      "lg" -> "medium"
      _ -> "small"
    end
  end

  # Gradient color based on email hash (consistent per user)
  defp gradient_for_email(nil), do: Enum.at(@gradients, 0)

  defp gradient_for_email(email) when is_binary(email) do
    index = :erlang.phash2(email, length(@gradients))
    Enum.at(@gradients, index)
  end

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
