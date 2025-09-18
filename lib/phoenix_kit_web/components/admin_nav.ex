defmodule PhoenixKitWeb.AdminNav do
  @moduledoc """
  Admin navigation components for the PhoenixKit admin panel.
  Provides consistent navigation elements for both desktop sidebar and mobile drawer.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  alias PhoenixKit.Utils.Routes

  @doc """
  Renders an admin navigation item with proper active state styling.

  ## Examples

      <.admin_nav_item
        href={Routes.path("/admin/dashboard")}
        icon="dashboard"
        label="Dashboard"
        current_path={Routes.path("/admin/dashboard")}
      />

      <.admin_nav_item
        href={Routes.path("/admin/users")}
        icon="users"
        label="Users"
        current_path={Routes.path("/admin/dashboard")}
        mobile={true}
      />
  """
  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, default: nil
  attr :current_path, :string, required: true
  attr :mobile, :boolean, default: false
  attr :nested, :boolean, default: false
  attr :disable_active, :boolean, default: false

  def admin_nav_item(assigns) do
    active =
      if assigns.disable_active,
        do: false,
        else: nav_item_active?(assigns.current_path, assigns.href)

    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      href={@href}
      class={[
        "flex items-center py-2 rounded-lg text-sm font-medium transition-colors",
        "hover:bg-base-200 group",
        if(@active,
          do: "bg-primary text-primary-content",
          else: "text-base-content hover:text-primary"
        ),
        if(@mobile, do: "w-full", else: ""),
        if(@nested, do: "pl-8 pr-3", else: "px-3")
      ]}
    >
      <%= if @nested do %>
        <!-- Nested item indicator -->
        <div class="w-4 h-4 mr-2 flex items-center justify-center">
          <div class="w-1.5 h-1.5 bg-current opacity-50 rounded-full"></div>
        </div>
        <span class="text-sm">{@label}</span>
      <% else %>
        <.admin_nav_icon icon={@icon} active={@active} />
        <span class="ml-3 font-medium">{@label}</span>
      <% end %>
    </.link>
    """
  end

  @doc """
  Renders an icon for admin navigation items.
  """
  attr :icon, :string, required: true
  attr :active, :boolean, default: false

  def admin_nav_icon(assigns) do
    ~H"""
    <div class="flex-shrink-0">
      <%= case @icon do %>
        <% "dashboard" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_dashboard />
        <% "users" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_users />
        <% "roles" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_roles />
        <% "modules" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_modules />
        <% "settings" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_settings />
        <% "sessions" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_sessions />
        <% "live_sessions" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_live_sessions />
        <% "referral_codes" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_referral_codes />
        <% "email" -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_email />
        <% _ -> %>
          <PhoenixKitWeb.Components.Core.Icons.icon_default />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders theme controller for admin panel.
  Based on EZNews theme system with DaisyUI integration.
  """
  attr :mobile, :boolean, default: false

  def admin_theme_controller(assigns) do
    ~H"""
    <div class={[
      "card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full",
      if(@mobile, do: "scale-90", else: "")
    ]}>
      <!-- Animated slider -->
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />
      
    <!-- System theme button -->
      <button
        class="flex p-2 cursor-pointer w-1/3 justify-center items-center tooltip z-10 relative"
        phx-click={JS.dispatch("phx:set-admin-theme", detail: %{theme: "system"})}
        data-tip="System theme"
        data-theme-target="system"
      >
        <PhoenixKitWeb.Components.Core.Icons.icon_system />
      </button>
      
    <!-- Light theme button -->
      <button
        class="flex p-2 cursor-pointer w-1/3 justify-center items-center tooltip z-10 relative"
        phx-click={JS.dispatch("phx:set-admin-theme", detail: %{theme: "light"})}
        data-tip="Light theme"
        data-theme-target="light"
      >
        <PhoenixKitWeb.Components.Core.Icons.icon_light />
      </button>
      
    <!-- Dark theme button -->
      <button
        class="flex p-2 cursor-pointer w-1/3 justify-center items-center tooltip z-10 relative"
        phx-click={JS.dispatch("phx:set-admin-theme", detail: %{theme: "dark"})}
        data-tip="Dark theme"
        data-theme-target="dark"
      >
        <PhoenixKitWeb.Components.Core.Icons.icon_dark />
      </button>
    </div>
    """
  end

  @doc """
  Renders user information section for admin panel sidebar.
  Shows current user email and role information.
  """
  attr :scope, :any, default: nil

  def admin_user_info(assigns) do
    ~H"""
    <%= if @scope && PhoenixKit.Users.Auth.Scope.authenticated?(@scope) do %>
      <div class="bg-base-200 rounded-lg p-3 text-sm">
        <div class="flex items-center gap-2 mb-2">
          <div class="w-8 h-8 bg-primary rounded-full flex items-center justify-center text-primary-content text-xs font-bold">
            {String.first(PhoenixKit.Users.Auth.Scope.user_email(@scope) || "?") |> String.upcase()}
          </div>
          <div class="flex-1 min-w-0">
            <div class="truncate text-xs font-medium text-base-content">
              {PhoenixKit.Users.Auth.Scope.user_email(@scope)}
            </div>
            <%= if PhoenixKit.Users.Auth.Scope.owner?(@scope) do %>
              <div class="badge badge-error badge-xs">Owner</div>
            <% else %>
              <%= if PhoenixKit.Users.Auth.Scope.admin?(@scope) do %>
                <div class="badge badge-warning badge-xs">Admin</div>
              <% else %>
                <div class="badge badge-ghost badge-xs">User</div>
              <% end %>
            <% end %>
          </div>
        </div>

        <div class="flex gap-1">
          <.link
            href={Routes.path("/users/settings")}
            class="btn btn-ghost btn-xs flex-1"
          >
            <PhoenixKitWeb.Components.Core.Icons.icon_settings class="w-3 h-3" />
          </.link>

          <.link
            href={Routes.path("/users/log-out")}
            method="delete"
            class="btn btn-ghost btn-xs flex-1 text-error hover:bg-error hover:text-error-content"
          >
            <PhoenixKitWeb.Components.Core.Icons.icon_logout />
          </.link>
        </div>
      </div>
    <% else %>
      <div class="bg-base-200 rounded-lg p-3 text-center text-sm">
        <div class="text-base-content/70 mb-2">Not authenticated</div>
        <.link href={Routes.path("/users/log-in")} class="btn btn-primary btn-sm w-full">
          Login
        </.link>
      </div>
    <% end %>
    """
  end

  # Helper function to determine if navigation item is active
  defp nav_item_active?(current_path, href) do
    current_parts = parse_admin_path(current_path)
    href_parts = parse_admin_path(href)

    exact_match?(current_parts, href_parts) or
      tab_match?(current_parts, href_parts) or
      parent_match?(current_parts, href_parts)
  end

  # Check if paths match exactly
  defp exact_match?(current_parts, href_parts) do
    href_parts.base_path == current_parts.base_path &&
      is_nil(href_parts.tab) &&
      is_nil(current_parts.tab)
  end

  # Check if tab-specific paths match
  defp tab_match?(current_parts, href_parts) do
    href_parts.base_path == current_parts.base_path &&
      href_parts.tab == current_parts.tab
  end

  # Check if parent page matches when on a tab
  defp parent_match?(current_parts, href_parts) do
    href_parts.base_path == current_parts.base_path &&
      is_nil(href_parts.tab) &&
      not is_nil(current_parts.tab)
  end

  # Helper function to parse admin path into components
  defp parse_admin_path(path) when is_binary(path) do
    # Remove query parameters and split path
    [path_part | _] = String.split(path, "?")

    # Get dynamic prefix and normalize paths
    prefix = PhoenixKit.Config.get_url_prefix()
    admin_prefix = if prefix == "/", do: "/admin", else: "#{prefix}/admin"

    base_path =
      path_part
      |> String.replace_prefix(admin_prefix, "")
      |> String.replace_prefix(prefix, "")
      |> case do
        # Default to dashboard for root
        "" -> "dashboard"
        "/" -> "dashboard"
        path -> String.trim_leading(path, "/")
      end

    # Extract tab parameter if present
    tab =
      if String.contains?(path, "?tab=") do
        path
        |> String.split("?tab=")
        |> List.last()
        |> String.split("&")
        |> List.first()
      else
        nil
      end

    %{base_path: base_path, tab: tab}
  end

  defp parse_admin_path(_), do: %{base_path: "dashboard", tab: nil}
end
