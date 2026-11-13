defmodule PhoenixKitWeb.Components.Core.UserInfo do
  @moduledoc """
  Provides user information display components.

  These components handle user-related data display including roles,
  statistics, avatars, and user counts. All components are designed to work
  with PhoenixKit's user and role system.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.AvatarCrop
  alias PhoenixKit.Users.AvatarShape
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles

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
  1. Uploaded avatar (custom_fields["avatar_file_uuid"]) - PhoenixKit Storage
  2. OAuth avatar (custom_fields["oauth_avatar_url"]) - Google/GitHub/etc
  3. Gravatar - by email hash (with d=404 for fallback detection)
  4. Gradient initials - colored background based on email hash

  ## Attributes
  - `user` - User struct with email and optional custom_fields
  - `size` - Avatar size: "xs" (w-6), "sm" (w-8), "md" (w-10), "lg" (w-12), "card" (w-16, a grid card's header), "xl" (w-40). Defaults to "sm"
  - `class` - Additional CSS classes
  - `peek` - Show the picture larger while the pointer is over it (lists of
    small avatars). The preview floats above the page, placed by
    `phoenix_kit_admin.js` (it shows on admin and dashboard pages, where that
    file loads; elsewhere the avatar is shown as usual), so a scrolling table
    does not clip it. Only an avatar
    with a picture gets one: enlarged initials show nothing new.
  - `shape` - An `AvatarShape` key to draw in; defaults to the site's shape
    (Settings → Users → Avatars). A border or ring on a masked shape is
    masked away along its curves (`AvatarShape.masked?/1`).

  ## Examples

      <.user_avatar user={user} />
      <.user_avatar user={user} size="lg" />
      <.user_avatar user={user} size="xs" class="ring ring-primary" />
  """
  attr :user, :map, required: true
  attr :size, :string, default: "sm"
  attr :class, :string, default: ""
  attr :shape, :string, default: nil
  attr :peek, :boolean, default: false

  # The size the hover preview is drawn at, in CSS pixels; phoenix_kit_admin.js
  # (AvatarPeek) draws it at the same size.
  @peek_px 176

  def user_avatar(assigns) do
    email = get_email(assigns.user)
    avatar_result = get_avatar_source(assigns.user, assigns.size)

    # A stored crop only applies to the uploaded file it was made against —
    # OAuth and Gravatar avatars have no variants and no crop.
    crop =
      case avatar_result do
        {:storage, _file_id, _variant} -> AvatarCrop.from_user(assigns.user)
        _ -> nil
      end

    avatar_url =
      case avatar_result do
        {:storage, file_id, variant} ->
          # A zoomed crop shows only part of the source, so it may need a
          # bigger variant than the box alone would: the geometry is free,
          # the sharpness has to come from somewhere.
          variant =
            if crop,
              do: AvatarCrop.variant_for(box_px(assigns.size), crop["zoom"], crop["ar"]),
              else: variant

          URLSigner.signed_url(file_id, variant)

        {:url, url} ->
          url

        {:gravatar, url} ->
          url

        nil ->
          nil
      end

    peek_url = if assigns.peek, do: peek_url(avatar_result, crop, email)

    size_classes = size_classes(assigns.size)
    gradient = gradient_for_email(email)
    initial = get_user_initial(assigns.user)

    assigns =
      assigns
      |> assign(:avatar_url, avatar_url)
      |> assign(:peek_url, peek_url)
      |> assign(:crop_style, crop && AvatarCrop.img_style(crop))
      |> assign(:shape_class, AvatarShape.class(assigns.shape || AvatarShape.current()))
      |> assign(:size_classes, size_classes)
      |> assign(:gradient, gradient)
      |> assign(:initial, initial)

    ~H"""
    <div
      class={["avatar", if(@avatar_url, do: "", else: "placeholder")]}
      data-avatar-peek={@peek_url}
    >
      <div
        data-avatar-frame={@peek_url && true}
        class={[
          @shape_class,
          "overflow-hidden relative flex items-center justify-center",
          if(@avatar_url, do: "bg-neutral", else: ["bg-gradient-to-br", @gradient]),
          "text-white font-bold",
          @size_classes,
          @class
        ]}
      >
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
          <%!-- Image overlay (hides fallback when loaded successfully).
               With a stored crop the geometry arrives as an inline style;
               without one, classic object-cover. One tag either way, so
               future img attributes cannot drift between branches. --%>
          <img
            src={@avatar_url}
            alt={gettext("Avatar")}
            style={@crop_style}
            class={unless @crop_style, do: "absolute inset-0 w-full h-full object-cover"}
            onerror="this.style.display='none';"
          />
        <% else %>
          <span>{@initial}</span>
        <% end %>
      </div>
    </div>
    """
  end

  # The hover preview loads a picture sized for itself; the small avatar's
  # would be blurry at that size. Enlarged initials show nothing new: nil.
  defp peek_url({:storage, file_id, _variant}, crop, _email) do
    variant =
      if crop,
        do: AvatarCrop.variant_for(@peek_px, crop["zoom"], crop["ar"]),
        else: AvatarCrop.variant_for(@peek_px)

    URLSigner.signed_url(file_id, variant)
  end

  defp peek_url({:gravatar, _url}, _crop, email), do: gravatar_url(email, @peek_px * 2)
  defp peek_url({:url, url}, _crop, _email), do: url
  defp peek_url(nil, _crop, _email), do: nil

  # Avatar source resolution (cascading priority)
  defp get_avatar_source(user, size) do
    cond do
      # 1. Custom uploaded avatar (highest priority)
      avatar_file_uuid = get_avatar_file_uuid(user) ->
        {:storage, avatar_file_uuid, storage_size(size)}

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

  defp get_avatar_file_uuid(nil), do: nil

  defp get_avatar_file_uuid(%{custom_fields: %{"avatar_file_uuid" => file_id}})
       when is_binary(file_id) and file_id != "",
       do: file_id

  defp get_avatar_file_uuid(_user), do: nil

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
      "card" -> 128
      "xl" -> 320
      _ -> 64
    end
  end

  # The CSS box each size renders into, for picking a variant that stays
  # sharp under the crop's zoom (2x displays assumed).
  defp box_px(size) do
    case size do
      "xs" -> 24
      "sm" -> 32
      "md" -> 40
      "lg" -> 48
      "card" -> 64
      "xl" -> 160
      _ -> 32
    end
  end

  # Size classes for the avatar container
  defp size_classes(size) do
    case size do
      "xs" -> "w-6 h-6 text-[10px]"
      "sm" -> "w-8 h-8 text-xs"
      "md" -> "w-10 h-10 text-sm"
      "lg" -> "w-12 h-12 text-base"
      "card" -> "w-16 h-16 text-xl"
      "xl" -> "w-40 h-40 text-5xl"
      _ -> "w-8 h-8 text-xs"
    end
  end

  # Storage size for PhoenixKit Storage. The settings page's "xl" preview
  # was the reported blur: it used to load the 150px thumbnail into a 160px
  # (320px on 2x displays) circle. It gets "medium" (800px) like the admin
  # form always did.
  defp storage_size(size) do
    case size do
      "xs" -> "small"
      "sm" -> "small"
      "md" -> "medium"
      "lg" -> "medium"
      "card" -> "medium"
      "xl" -> "medium"
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
  - `stats` - Map with role statistics (role_uuid => count)

  ## Examples

      <.users_count role={role} stats={@role_stats} />
      <.users_count role={role} stats={@role_stats} />
  """
  attr :role, :map, required: true
  attr :stats, :map, required: true

  def users_count(assigns) do
    ~H"""
    <span class="font-medium">
      {Map.get(@stats, @role.name, 0)}
    </span>
    """
  end

  # Private helpers

  defp get_primary_role_name(user) do
    case user.roles do
      [] -> gettext("No role")
      [%Role{} = role | _] -> Roles.display_name(role)
      _ -> gettext("No role")
    end
  end
end
