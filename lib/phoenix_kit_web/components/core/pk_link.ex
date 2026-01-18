defmodule PhoenixKitWeb.Components.Core.PkLink do
  @moduledoc """
  Provides prefix-aware link components for PhoenixKit navigation.

  These components automatically apply the configured PhoenixKit URL prefix
  to paths, ensuring links work correctly regardless of the prefix configuration.

  ## Why Use These Components?

  PhoenixKit supports a configurable URL prefix (default: `/phoenix_kit`).
  Using these components instead of hardcoded paths ensures your links
  work correctly when the prefix changes.

  ## Examples

      # Instead of hardcoding:
      <.link navigate="/phoenix_kit/dashboard">Dashboard</.link>

      # Use pk_link for automatic prefix handling:
      <.pk_link navigate="/dashboard">Dashboard</.pk_link>

      # Works with all link types:
      <.pk_link navigate="/admin/users">Users</.pk_link>
      <.pk_link patch="/dashboard?tab=settings">Settings</.pk_link>
      <.pk_link href="/api/export">Export</.pk_link>

  ## Configuration

  The URL prefix is configured in your application:

      config :phoenix_kit, url_prefix: "/my_prefix"

  """

  use Phoenix.Component

  alias PhoenixKit.Utils.Routes

  @doc """
  Renders a link with automatic PhoenixKit URL prefix handling.

  This component wraps Phoenix's `<.link>` and automatically prepends
  the configured PhoenixKit URL prefix to the path.

  ## Attributes

    * `navigate` - The path for LiveView navigation (full page load within LiveView)
    * `patch` - The path for LiveView patch (updates URL without full navigation)
    * `href` - The path for standard HTTP navigation
    * `class` - CSS classes to apply
    * `replace` - When true, replaces browser history instead of pushing

  Only one of `navigate`, `patch`, or `href` should be provided.

  ## Examples

      <.pk_link navigate="/dashboard">Dashboard</.pk_link>

      <.pk_link navigate="/admin/users" class="btn btn-primary">
        Manage Users
      </.pk_link>

      <.pk_link patch="/settings" replace={true}>
        Settings
      </.pk_link>

  """
  attr :navigate, :string, default: nil, doc: "Path for LiveView navigate"
  attr :patch, :string, default: nil, doc: "Path for LiveView patch"
  attr :href, :string, default: nil, doc: "Path for standard href"
  attr :class, :string, default: nil
  attr :replace, :boolean, default: false
  attr :rest, :global, include: ~w(download hreflang referrerpolicy rel target type)

  slot :inner_block, required: true

  def pk_link(assigns) do
    assigns = apply_prefix(assigns)

    ~H"""
    <.link
      navigate={@navigate}
      patch={@patch}
      href={@href}
      class={@class}
      replace={@replace}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Renders a button-styled link with automatic PhoenixKit URL prefix handling.

  Convenience component that combines `pk_link` with button styling.

  ## Examples

      <.pk_link_button navigate="/dashboard">Dashboard</.pk_link_button>

      <.pk_link_button navigate="/admin/users" variant="secondary">
        Manage Users
      </.pk_link_button>

  """
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  attr :class, :string, default: nil
  attr :variant, :string, default: "primary", values: ~w(primary secondary ghost link outline)
  attr :replace, :boolean, default: false
  attr :rest, :global

  slot :inner_block, required: true

  def pk_link_button(assigns) do
    assigns = apply_prefix(assigns)

    ~H"""
    <.link
      navigate={@navigate}
      patch={@patch}
      href={@href}
      class={["btn btn-#{@variant}", @class]}
      replace={@replace}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # Applies the PhoenixKit URL prefix to whichever path attribute is set
  defp apply_prefix(assigns) do
    cond do
      assigns[:navigate] ->
        assign(assigns, :navigate, Routes.path(assigns.navigate))

      assigns[:patch] ->
        assign(assigns, :patch, Routes.path(assigns.patch))

      assigns[:href] ->
        assign(assigns, :href, Routes.path(assigns.href))

      true ->
        assigns
    end
  end
end
