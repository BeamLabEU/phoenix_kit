defmodule PhoenixKitWeb.Components.UserDashboardNav do
  @moduledoc """
  User dashboard navigation components for the PhoenixKit user dashboard.
  Provides navigation elements specifically for user dashboard pages.
  """

  use PhoenixKitWeb, :html

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @doc """
  Renders user dropdown for dashboard navigation.
  Shows user avatar with dropdown menu containing email, role, settings and logout.
  """
  attr(:scope, :any, default: nil)
  attr(:current_path, :string, default: "")
  attr(:current_locale, :string, default: "en")

  def user_dropdown(assigns) do
    user = Scope.user(assigns.scope)
    avatar_file_id = user && user.custom_fields && user.custom_fields["avatar_file_id"]

    assigns =
      assigns
      |> assign(:avatar_file_id, avatar_file_id)
      |> assign(:user, user)

    ~H"""
    <%= if @scope && PhoenixKit.Users.Auth.Scope.authenticated?(@scope) do %>
      <div class="dropdown dropdown-end">
        <div
          tabindex="0"
          role="button"
          class="w-10 h-10 rounded-lg bg-primary flex items-center justify-center text-primary-content font-bold cursor-pointer hover:opacity-80 transition-opacity overflow-hidden"
        >
          <%= if @avatar_file_id do %>
            <% avatar_url = PhoenixKit.Modules.Storage.URLSigner.signed_url(@avatar_file_id, "medium") %>
            <img
              src={avatar_url}
              alt="Avatar"
              class="w-full h-full object-cover"
              onerror="this.style.display='none'; this.nextElementSibling.style.display='flex';"
            />
            <div class="hidden w-full h-full bg-primary flex items-center justify-center text-primary-content font-bold">
              {String.first(@user.email || "?") |> String.upcase()}
            </div>
          <% else %>
            {String.first(PhoenixKit.Users.Auth.Scope.user_email(@scope) || "?") |> String.upcase()}
          <% end %>
        </div>

        <ul
          tabindex="0"
          class="dropdown-content menu bg-base-100 rounded-box z-[60] w-64 p-2 shadow-xl border border-base-300 mt-3"
        >
          <li class="menu-title px-4 py-2">
            <div class="flex flex-col gap-1">
              <span class="text-sm font-medium text-base-content truncate">
                {PhoenixKit.Users.Auth.Scope.user_email(@scope)}
              </span>
            </div>
          </li>

          <div class="divider my-0"></div>

          <li>
            <a
              href={PhoenixKit.Utils.Routes.path("/dashboard", locale: @current_locale)}
              class={"flex items-center gap-3" <> if(active_path?(assigns[:current_path], "/dashboard"), do: " bg-primary text-primary-content", else: "")}
            >
              <.icon name="hero-home" class="w-4 h-4" />
              <span>Dashboard</span>
            </a>
          </li>

          <li>
            <a
              href={PhoenixKit.Utils.Routes.path("/dashboard/settings", locale: @current_locale)}
              class={"flex items-center gap-3" <> if(active_path?(assigns[:current_path], "/dashboard/settings"), do: " bg-primary text-primary-content", else: "")}
            >
              <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
              <span>Settings</span>
            </a>
          </li>

          <li>
            <div class="menu-title px-4 py-1">
              <span class="text-xs">Theme</span>
            </div>
          </li>
          <li>
            <label class="flex items-center justify-between px-3 py-2 cursor-pointer">
              <!-- Text area -->
              <span class="text-sm">
                Dark Mode
              </span>
              <!-- Icon area with checkbox -->
              <div class="swap swap-rotate swap-flip">
                <input
                  type="checkbox"
                  class="theme-controller"
                  value="dark"
                />
                <.icon name="hero-sun" class="swap-off w-4 h-4" />
                <.icon name="hero-moon" class="swap-on w-4 h-4" />
              </div>
            </label>
          </li>

          <% user_languages = get_user_languages() %>
          <%= if length(user_languages) > 1 do %>
            <div class="divider my-0"></div>

            <li class="menu-title px-4 py-1">
              <span class="text-xs">Language</span>
            </li>

            <%= for language <- user_languages do %>
              <li>
                <a
                  href={generate_language_switch_url(@current_path, language["code"])}
                  class={[
                    "flex items-center gap-3",
                    if(language["code"] == @current_locale, do: "active", else: "")
                  ]}
                >
                  <span class="text-lg">{get_language_flag(language["code"])}</span>
                  <span>{language["name"]}</span>
                  <%= if language["code"] == @current_locale do %>
                    <PhoenixKitWeb.Components.Core.Icons.icon_check class="w-4 h-4 ml-auto" />
                  <% end %>
                </a>
              </li>
            <% end %>
          <% end %>

          <div class="divider my-0"></div>

          <li>
            <.link
              navigate="/users/log-out"
              method="delete"
              class="flex items-center gap-3 text-error hover:bg-error hover:text-error-content"
            >
              <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4" />
              <span>Log Out</span>
            </.link>
          </li>
        </ul>
      </div>
    <% else %>
      <.link
        navigate="/users/log-in"
        class="btn btn-primary btn-sm"
      >
        Login
      </.link>
    <% end %>
    """
  end

  # Helper function to get user languages from Languages module
  # Returns enabled languages or falls back to English if module is disabled
  defp get_user_languages do
    # Get enabled languages from the Languages module
    languages =
      if Languages.enabled?() do
        Languages.get_enabled_languages()
      else
        # Fallback to English when module is disabled
        [%{"code" => "en-US", "name" => "English (United States)", "is_enabled" => true}]
      end

    # Map to expected format
    languages
    |> Enum.map(fn lang ->
      case Languages.get_predefined_language(lang["code"]) do
        %{name: name, flag: flag, native: native} ->
          %{"code" => lang["code"], "name" => name, "flag" => flag, "native" => native}

        nil ->
          %{
            "code" => lang["code"],
            "name" => String.upcase(lang["code"]),
            "flag" => "🌐",
            "native" => ""
          }
      end
    end)
  end

  # Helper function to get language flag emoji
  defp get_language_flag(code) when is_binary(code) do
    case Languages.get_predefined_language(code) do
      %{flag: flag} -> flag
      nil -> "🌐"
    end
  end

  # Check if current path matches the given path
  defp active_path?(current_path, path) when is_binary(current_path) and is_binary(path) do
    # Remove PhoenixKit prefix if present
    normalized_path = remove_phoenix_kit_prefix(current_path)
    # Remove locale prefix if present
    clean_path = remove_locale_prefix(normalized_path)

    # Check for exact match or ends with path
    clean_path == path or String.ends_with?(clean_path, path)
  end

  defp active_path?(_, _), do: false

  # Remove PhoenixKit prefix
  defp remove_phoenix_kit_prefix(path) do
    url_prefix = PhoenixKit.Config.get_url_prefix()

    if url_prefix == "/" do
      path
    else
      String.replace_prefix(path, url_prefix, "")
    end
  end

  # Remove locale prefix
  defp remove_locale_prefix(path) do
    case String.split(path, "/", parts: 3) do
      ["", locale, rest] when locale != "" and rest != "" ->
        if looks_like_locale?(locale), do: "/" <> rest, else: path

      ["", locale] ->
        if looks_like_locale?(locale), do: "/", else: path

      _ ->
        path
    end
  end

  # Check if it looks like a locale code
  defp looks_like_locale?(locale) do
    String.length(locale) <= 6 and String.match?(locale, ~r/^[a-z]{2}(-[A-Z]{2})?$/)
  end

  # Legacy helper - kept for backward compatibility
  defp generate_language_switch_url(current_path, new_locale) do
    alias PhoenixKit.Modules.Languages.DialectMapper
    base_code = DialectMapper.extract_base(new_locale)

    # Extract the path without locale and regenerate with new locale
    url_prefix = PhoenixKit.Config.get_url_prefix()
    base_prefix = if url_prefix === "/", do: "", else: url_prefix

    # Remove prefix and locale from current_path
    clean_path =
      current_path
      |> String.replace_prefix(base_prefix, "")
      |> remove_locale_from_path()

    # Generate new path with the new locale
    Routes.path(clean_path, locale: base_code)
  end

  # Remove locale from path
  defp remove_locale_from_path(path) do
    case String.split(path, "/", trim: true) do
      [segment | rest] when byte_size(segment) in [2, 5] ->
        # Check if segment looks like a locale
        if String.length(segment) == 2 or
             (String.length(segment) == 5 and String.contains?(segment, "-")) do
          "/" <> Path.join(rest)
        else
          path
        end

      _ ->
        path
    end
  end
end
