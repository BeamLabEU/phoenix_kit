defmodule PhoenixKitWeb.Components.Core.Icons do
  @moduledoc """
  Provides icons for other components and interfaces.
  """
  use Phoenix.Component

  @doc """
  A component for an arrow to left.
  """
  attr :class, :string, default: "w-4 h-4 mr-2"

  def icon_arrow_left(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M10 19l-7-7m0 0l7-7m-7 7h18"
      >
      </path>
    </svg>
    """
  end

  @doc """
  Dashboard icon component.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_dashboard(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
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
    """
  end

  @doc """
  Users icon component.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_users(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0zM5 21v-1a6 6 0 0112 0v1z"
      />
    </svg>
    """
  end

  @doc """
  Roles icon component.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_roles(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M9 12l2 2 4-4M7.835 4.697a3.42 3.42 0 001.946-.806 3.42 3.42 0 014.438 0 3.42 3.42 0 001.946.806 3.42 3.42 0 013.138 3.138 3.42 3.42 0 00.806 1.946 3.42 3.42 0 010 4.438 3.42 3.42 0 00-.806 1.946 3.42 3.42 0 01-3.138 3.138 3.42 3.42 0 00-1.946.806 3.42 3.42 0 01-4.438 0 3.42 3.42 0 00-1.946-.806 3.42 3.42 0 01-3.138-3.138 3.42 3.42 0 00-.806-1.946 3.42 3.42 0 010-4.438 3.42 3.42 0 00.806-1.946 3.42 3.42 0 013.138-3.138z"
      />
    </svg>
    """
  end

  @doc """
  Modules icon component.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_modules(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"
      />
    </svg>
    """
  end

  @doc """
  Settings icon component.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_settings(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
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
    """
  end

  @doc """
  Sessions icon component.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_sessions(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
      />
    </svg>
    """
  end

  @doc """
  Live sessions icon component.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_live_sessions(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z"
      />
    </svg>
    """
  end

  @doc """
  Referral codes icon component.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_referral_codes(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M15 5v2m0 4v2m0 4v2M5 5a2 2 0 00-2 2v3a2 2 0 002 2h14a2 2 0 002-2V7a2 2 0 00-2-2H5zM5 14a2 2 0 00-2 2v3a2 2 0 002 2h14a2 2 0 002-2v-3a2 2 0 00-2-2H5z"
      />
    </svg>
    """
  end

  @doc """
  Email icon component.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_email(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
      />
    </svg>
    """
  end

  @doc """
  System theme icon component (monitor).
  """
  attr :class, :string, default: "size-4 opacity-75 hover:opacity-100"

  def icon_system(assigns) do
    ~H"""
    <svg
      class={@class}
      xmlns="http://www.w3.org/2000/svg"
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <rect x="2" y="3" width="20" height="14" rx="2" ry="2"></rect>
      <line x1="8" y1="21" x2="16" y2="21"></line>
      <line x1="12" y1="17" x2="12" y2="21"></line>
    </svg>
    """
  end

  @doc """
  Light theme icon component (sun).
  """
  attr :class, :string, default: "size-4 opacity-75 hover:opacity-100"

  def icon_light(assigns) do
    ~H"""
    <svg
      class={@class}
      xmlns="http://www.w3.org/2000/svg"
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <circle cx="12" cy="12" r="5"></circle>
      <path d="M12 1v2M12 21v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M1 12h2M21 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4">
      </path>
    </svg>
    """
  end

  @doc """
  Dark theme icon component (moon).
  """
  attr :class, :string, default: "size-4 opacity-75 hover:opacity-100"

  def icon_dark(assigns) do
    ~H"""
    <svg
      class={@class}
      xmlns="http://www.w3.org/2000/svg"
      width="16"
      height="16"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path>
    </svg>
    """
  end

  @doc """
  Logout icon component.
  """
  attr :class, :string, default: "w-3 h-3"

  def icon_logout(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"
      />
    </svg>
    """
  end

  @doc """
  Menu icon component (hamburger).
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_menu(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M4 6h16M4 12h16M4 18h16"
      />
    </svg>
    """
  end

  @doc """
  Shield icon component.
  """
  attr :class, :string, default: "w-5 h-5 text-primary-content"

  def icon_shield(assigns) do
    ~H"""
    <svg
      class={@class}
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.031 9-11.622 0-1.042-.133-2.052-.382-3.016z"
      />
    </svg>
    """
  end

  @doc """
  Default icon component for unknown icon types.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_default(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M12 6V4m0 2a2 2 0 100 4m0-4a2 2 0 110 4m-6 8a2 2 0 100-4m0 4a2 2 0 100 4m0-4v2m0-6V4m6 6v10m6-2a2 2 0 100-4m0 4a2 2 0 100 4m0-4v2m0-6V4"
      />
    </svg>
    """
  end

  @doc """
  User add icon component (user with plus sign).
  """
  attr :class, :string, default: "w-4 h-4 mr-2"

  def icon_user_add(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M18 9v3m0 0v3m0-3h3m-3 0h-3m-2-5a4 4 0 11-8 0 4 4 0 018 0zM3 20a6 6 0 0112 0v1H3v-1z"
      />
    </svg>
    """
  end

  @doc """
  Eye icon component for viewing/visibility.
  """
  attr :class, :string, default: "w-8 h-8 mr-3"

  def icon_eye(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
      />
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
      />
    </svg>
    """
  end

  @doc """
  Warning triangle icon component.
  """
  attr :class, :string, default: "stroke-current shrink-0 h-5 w-5"

  def icon_warning(assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.732-.833-2.5 0L4.268 16.5c-.77.833.192 2.5 1.732 2.5z"
      />
    </svg>
    """
  end

  @doc """
  Error circle icon component with X.
  """
  attr :class, :string, default: "stroke-current shrink-0 h-6 w-6"

  def icon_error_circle(assigns) do
    ~H"""
    <svg class={@class} fill="none" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
      />
    </svg>
    """
  end

  @doc """
  Warning icon component (filled triangle).
  """
  attr :class, :string, default: "w-6 h-6 text-yellow-600 dark:text-warning mt-0.5"

  def icon_warning_filled(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 20 20">
      <path
        fill-rule="evenodd"
        d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  @doc """
  Info icon component.
  """
  attr :class, :string, default: "w-5 h-5 mt-0.5 text-info"

  def icon_info(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 20 20">
      <path
        fill-rule="evenodd"
        d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  @doc """
  Check icon component.
  """
  attr :class, :string, default: "w-4 h-4 inline mr-1"
  attr :"data-theme-active-indicator", :boolean, default: false

  def icon_check(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 20 20">
      <path
        fill-rule="evenodd"
        d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  @doc """
  X/Close icon component.
  """
  attr :class, :string, default: "w-4 h-4 mr-2"

  def icon_x(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M6 18L18 6M6 6l12 12"
      />
    </svg>
    """
  end

  @doc """
  Google icon component.
  """
  attr :class, :string, default: "h-5 w-5"

  def icon_google(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      class={@class}
      viewBox="0 0 24 24"
      fill="currentColor"
    >
      <path d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z" />
      <path d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" />
      <path d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z" />
      <path d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" />
    </svg>
    """
  end

  @doc """
  Apple icon component.
  """
  attr :class, :string, default: "h-5 w-5"

  def icon_apple(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      class={@class}
      viewBox="0 0 24 24"
      fill="currentColor"
    >
      <path d="M17.503 0c.132 1.243-.365 2.47-1.063 3.37-.698.901-1.865 1.607-2.996 1.514-.158-1.154.444-2.378 1.101-3.132C15.298.905 16.48.107 17.503 0zm3.478 7.018c-.196.118-3.003 1.753-2.976 5.227.032 4.149 3.638 5.531 3.678 5.547-.025.097-.574 1.968-1.894 3.899-1.142 1.673-2.326 3.343-4.194 3.376-1.835.033-2.425-1.089-4.521-1.089-2.097 0-2.752 1.056-4.489 1.122-1.803.066-3.178-1.809-4.327-3.479-2.357-3.426-4.157-9.682-1.739-13.901 1.198-2.092 3.342-3.418 5.665-3.453 1.77-.033 3.44 1.19 4.521 1.19 1.081 0 3.106-1.471 5.236-1.255.891.047 3.396.36 5.004 2.714-.13.081-2.987 1.746-2.964 5.202z" />
    </svg>
    """
  end

  @doc """
  GitHub icon component.
  """
  attr :class, :string, default: "h-5 w-5"

  def icon_github(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      class={@class}
      viewBox="0 0 24 24"
      fill="currentColor"
    >
      <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
    </svg>
    """
  end

  @doc """
  Facebook icon component.
  """
  attr :class, :string, default: "h-5 w-5"

  def icon_facebook(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      class={@class}
      viewBox="0 0 24 24"
      fill="currentColor"
    >
      <path d="M24 12.073c0-6.627-5.373-12-12-12s-12 5.373-12 12c0 5.99 4.388 10.954 10.125 11.854v-8.385H7.078v-3.47h3.047V9.43c0-3.007 1.792-4.669 4.533-4.669 1.312 0 2.686.235 2.686.235v2.953H15.83c-1.491 0-1.956.925-1.956 1.874v2.25h3.328l-.532 3.47h-2.796v8.385C19.612 23.027 24 18.062 24 12.073z" />
    </svg>
    """
  end

  @doc """
  Link icon component for connected accounts.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_link(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"
      />
    </svg>
    """
  end

  @doc """
  Refresh/Reload icon component.
  """
  attr :class, :string, default: "w-4 h-4 mr-1"

  def icon_refresh(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
      />
    </svg>
    """
  end

  @doc """
  X thin icon component for closing/canceling.
  """
  attr :class, :string, default: "w-3 h-3"

  def icon_x_thin(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M6 18L18 6M6 6l12 12"
      />
    </svg>
    """
  end

  @doc """
  Crown icon component for system owners.
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_crown(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24">
      <path d="M5 16L3 6l5.5 4L12 4l3.5 6L21 6l-2 10H5z" />
    </svg>
    """
  end

  @doc """
  Star icon component for administrators.
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_star(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24">
      <path d="M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01L12 2z" />
    </svg>
    """
  end

  @doc """
  Simple user icon component.
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_user_simple(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24">
      <path d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z" />
    </svg>
    """
  end

  @doc """
  Clock icon component with hands.
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_clock(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24">
      <path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8z" />
      <path d="M12.5 7H11v6l5.25 3.15.75-1.23-4.5-2.67z" />
    </svg>
    """
  end

  @doc """
  Expired clock icon component.
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_clock_expired(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24">
      <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm5 11h-6V7h2v4h4v2z" />
    </svg>
    """
  end

  @doc """
  Check circle filled icon component.
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_check_circle_filled(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 20 20">
      <path
        fill-rule="evenodd"
        d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
      />
    </svg>
    """
  end

  @doc """
  X circle filled icon component.
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_x_circle_filled(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 20 20">
      <path
        fill-rule="evenodd"
        d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z"
      />
    </svg>
    """
  end

  @doc """
  Info filled icon component.
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_info_filled(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24">
      <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 15h2v2h-2v-2zm0-8h2v6h-2V9z" />
    </svg>
    """
  end

  @doc """
  Anonymous user icon component.
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_user_anonymous(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24">
      <path
        d="M12 2c2.21 0 4 1.79 4 4s-1.79 4-4 4-4-1.79-4-4 1.79-4 4-4zm0 14c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z"
        opacity="0.6"
      />
      <circle cx="12" cy="6" r="1" fill="white" />
      <circle cx="12" cy="8" r="0.5" fill="white" />
    </svg>
    """
  end

  @doc """
  Check circle outline icon component.
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_check_circle_outline(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24">
      <path d="M10,17L6,13L7.41,11.59L10,14.17L16.59,7.58L18,9M12,2A10,10 0 0,0 2,12A10,10 0 0,0 12,22A10,10 0 0,0 22,12A10,10 0 0,0 12,2Z" />
    </svg>
    """
  end

  @doc """
  Multiple users icon component.
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_users_multiple(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24">
      <path d="M4 13c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm1.13 1.1c-.37-.06-.74-.1-1.13-.1C2.48 14 0 14.9 0 16.5V18h4.5v-1.5c0-.54.34-1.07.63-1.4zM20 13c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm1.13 1.1c-.37-.06-.74-.1-1.13-.1-1.52 0-4 .9-4 2.5V18H24v-1.5c0-.54-.34-1.07-.87-1.4zM12 12c1.93 0 3.5-1.57 3.5-3.5S13.93 5 12 5 8.5 6.57 8.5 8.5 10.07 12 12 12zm0 2c-2.33 0-7 1.17-7 3.5V19h14v-1.5c0-2.33-4.67-3.5-7-3.5z" />
    </svg>
    """
  end

  @doc """
  Activity/Sessions icon component.
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_activity(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24">
      <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm3.88 9.88l-4.24 4.24c-.78.78-2.05.78-2.83 0-.78-.78-.78-2.05 0-2.83L12.05 10l-3.24-3.29c-.78-.78-.78-2.05 0-2.83.78-.78 2.05-.78 2.83 0l4.24 4.24c.39.39.39 1.02 0 1.41z" />
    </svg>
    """
  end

  @doc """
  User profile icon component.
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_user_profile(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24">
      <path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z" />
    </svg>
    """
  end

  @doc """
  Auto-refresh ON icon component (clock with arrow).
  """
  attr :class, :string, default: "w-4 h-4 mr-1"

  def icon_auto_refresh_on(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M10 9v6l3-3m6-5a9 9 0 11-18 0 9 9 0 0118 0z"
      />
    </svg>
    """
  end

  @doc """
  Auto-refresh OFF icon component (arrows in opposite directions).
  """
  attr :class, :string, default: "w-4 h-4 mr-1"

  def icon_auto_refresh_off(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 0l-3-3m-6 0l3 3"
      />
    </svg>
    """
  end

  @doc """
  Sort ascending icon component (arrow up).
  """
  attr :class, :string, default: "w-3 h-3"

  def icon_sort_asc(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M5 15l7-7 7 7"
      />
    </svg>
    """
  end

  @doc """
  Sort descending icon component (arrow down).
  """
  attr :class, :string, default: "w-3 h-3"

  def icon_sort_desc(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M19 9l-7 7-7-7"
      />
    </svg>
    """
  end

  @doc """
  Empty inbox icon component.
  """
  attr :class, :string, default: "w-16 h-16 mx-auto mb-4"

  def icon_empty_inbox(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M20 13V6a2 2 0 00-2-2H6a2 2 0 00-2 2v7m16 0v5a2 2 0 01-2 2H6a2 2 0 01-2-2v-5m16 0h-2.586a1 1 0 00-.707.293l-2.414 2.414a1 1 0 01-.707.293h-3.172a1 1 0 01-.707-.293l-2.414-2.414A1 1 0 009.586 13H7"
      />
    </svg>
    """
  end

  @doc """
  Plus icon component (add/create action).
  """
  attr :class, :string, default: "w-4 h-4"

  def icon_plus(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M12 4v16m8-8H4"
      />
    </svg>
    """
  end

  @doc """
  Edit icon component (pencil for editing).
  """
  attr :class, :string, default: "w-4 h-4"

  def icon_edit(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
      />
    </svg>
    """
  end

  @doc """
  Trash icon component (delete action).
  """
  attr :class, :string, default: "w-4 h-4"

  def icon_trash(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
      />
    </svg>
    """
  end

  @doc """
  Ban/disable icon component (X with strikethrough).
  """
  attr :class, :string, default: "w-4 h-4"

  def icon_ban(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728L5.636 5.636m12.728 12.728L18.364 5.636M5.636 18.364l12.728-12.728"
      />
    </svg>
    """
  end

  @doc """
  Info filled icon component (filled circle with exclamation).
  """
  attr :class, :string, default: "w-6 h-6"

  def icon_info_circle_filled(assigns) do
    ~H"""
    <svg class={@class} fill="currentColor" viewBox="0 0 24 24">
      <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 15h2v2h-2v-2zm0-8h2v6h-2V9z" />
    </svg>
    """
  end

  @doc """
  Search icon component (magnifying glass).
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_search(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
      />
    </svg>
    """
  end

  @doc """
  Download icon component (arrow down with cloud).
  """
  attr :class, :string, default: "w-4 h-4"

  def icon_download(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M9 19l3 3m0 0l3-3m-3 3V10"
      />
    </svg>
    """
  end

  @doc """
  Lock icon component (padlock for security).
  """
  attr :class, :string, default: "w-4 h-4"

  def icon_lock(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
      />
    </svg>
    """
  end

  @doc """
  Login icon component (arrow entering a door).
  """
  attr :class, :string, default: "w-5 h-5 mr-2"

  def icon_login(assigns) do
    ~H"""
    <svg
      class={@class}
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      stroke-width="1.5"
      stroke="currentColor"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        d="M15.75 9V5.25A2.25 2.25 0 0013.5 3h-6a2.25 2.25 0 00-2.25 2.25v13.5A2.25 2.25 0 007.5 21h6a2.25 2.25 0 002.25-2.25V15M12 9l-3 3m0 0l3 3m-3-3h12.75"
      />
    </svg>
    """
  end

  @doc """
  Language/Globe icon component for language module.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_language(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M3 5h12M9 3v2m1.048 9.5A18.022 18.022 0 016.412 9m6.088 9h7M11 21l5-10 5 10M12.751 5C11.783 10.77 8.07 15.61 3 18.129"
      />
    </svg>
    """
  end

  @doc """
  Document/Pages icon component for pages module.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_document(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M7 21h10a2 2 0 002-2V9.414a1 1 0 00-.293-.707l-5.414-5.414A1 1 0 0012.586 3H7a2 2 0 00-2 2v14a2 2 0 002 2z"
      />
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M9 13h6M9 17h6M13 3v6a1 1 0 001 1h6"
      />
    </svg>
    """
  end

  @doc """
  Entities icon component for entities module.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_entities(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4"
      />
    </svg>
    """
  end

  @doc """
  Folder icon component.
  """
  attr :class, :string, default: "w-5 h-5"

  def icon_folder(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
      />
    </svg>
    """
  end

  @doc """
  Duplicate icon component (two overlapping documents).
  """
  attr :class, :string, default: "w-4 h-4"

  def icon_duplicate(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"
      />
    </svg>
    """
  end

  @doc """
  Copy icon component (document with plus).
  """
  attr :class, :string, default: "w-4 h-4"

  def icon_copy(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3"
      />
    </svg>
    """
  end

  @doc """
  Move icon component (arrows in/out).
  """
  attr :class, :string, default: "w-4 h-4"

  def icon_move(assigns) do
    ~H"""
    <svg class={@class} fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M7 16V4m0 0L3 8m4-4l4 4m6 0v12m0 0l4-4m-4 4l-4-4"
      />
    </svg>
    """
  end
end
