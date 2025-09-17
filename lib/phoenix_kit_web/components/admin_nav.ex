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
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2H5a2 2 0 00-2-2z"
            />
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M8 5a2 2 0 012-2h4a2 2 0 012 2v3H8V5z"
            />
          </svg>
        <% "users" -> %>
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0zM5 21v-1a6 6 0 0112 0v1z"
            />
          </svg>
        <% "roles" -> %>
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M9 12l2 2 4-4M7.835 4.697a3.42 3.42 0 001.946-.806 3.42 3.42 0 014.438 0 3.42 3.42 0 001.946.806 3.42 3.42 0 013.138 3.138 3.42 3.42 0 00.806 1.946 3.42 3.42 0 010 4.438 3.42 3.42 0 00-.806 1.946 3.42 3.42 0 01-3.138 3.138 3.42 3.42 0 00-1.946.806 3.42 3.42 0 01-4.438 0 3.42 3.42 0 00-1.946-.806 3.42 3.42 0 01-3.138-3.138 3.42 3.42 0 00-.806-1.946 3.42 3.42 0 010-4.438 3.42 3.42 0 00.806-1.946 3.42 3.42 0 013.138-3.138z"
            />
          </svg>
        <% "modules" -> %>
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"
            />
          </svg>
        <% "settings" -> %>
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
            />
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
            />
          </svg>
        <% "sessions" -> %>
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
            />
          </svg>
        <% "live_sessions" -> %>
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z"
            />
          </svg>
        <% "referral_codes" -> %>
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M15 5v2m0 4v2m0 4v2M5 5a2 2 0 00-2 2v3a2 2 0 002 2h14a2 2 0 002-2V7a2 2 0 00-2-2H5zM5 14a2 2 0 00-2 2v3a2 2 0 002 2h14a2 2 0 002-2v-3a2 2 0 00-2-2H5z"
            />
          </svg>
        <% "email" -> %>
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
            />
          </svg>
        <% _ -> %>
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 6V4m0 2a2 2 0 100 4m0-4a2 2 0 110 4m-6 8a2 2 0 100-4m0 4a2 2 0 100 4m0-4v2m0-6V4m6 6v10m6-2a2 2 0 100-4m0 4a2 2 0 100 4m0-4v2m0-6V4"
            />
          </svg>
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
        <svg
          xmlns="http://www.w3.org/2000/svg"
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          class="size-4 opacity-75 hover:opacity-100"
        >
          <rect x="2" y="3" width="20" height="14" rx="2" ry="2"></rect>
          <line x1="8" y1="21" x2="16" y2="21"></line>
          <line x1="12" y1="17" x2="12" y2="21"></line>
        </svg>
      </button>
      
    <!-- Light theme button -->
      <button
        class="flex p-2 cursor-pointer w-1/3 justify-center items-center tooltip z-10 relative"
        phx-click={JS.dispatch("phx:set-admin-theme", detail: %{theme: "light"})}
        data-tip="Light theme"
        data-theme-target="light"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          class="size-4 opacity-75 hover:opacity-100"
        >
          <circle cx="12" cy="12" r="5"></circle>
          <path d="M12 1v2M12 21v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M1 12h2M21 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4">
          </path>
        </svg>
      </button>
      
    <!-- Dark theme button -->
      <button
        class="flex p-2 cursor-pointer w-1/3 justify-center items-center tooltip z-10 relative"
        phx-click={JS.dispatch("phx:set-admin-theme", detail: %{theme: "dark"})}
        data-tip="Dark theme"
        data-theme-target="dark"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          class="size-4 opacity-75 hover:opacity-100"
        >
          <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path>
        </svg>
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
            <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
              />
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
              />
            </svg>
          </.link>

          <.link
            href={Routes.path("/users/log-out")}
            method="delete"
            class="btn btn-ghost btn-xs flex-1 text-error hover:bg-error hover:text-error-content"
          >
            <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"
              />
            </svg>
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
