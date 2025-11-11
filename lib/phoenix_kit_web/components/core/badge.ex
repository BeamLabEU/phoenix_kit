defmodule PhoenixKitWeb.Components.Core.Badge do
  @moduledoc """
  Provides badge UI components for status, roles, and labels.

  Supports different variants for system roles, user statuses, and custom labels.
  All badge components follow daisyUI badge styling conventions.
  """

  use Phoenix.Component

  @doc """
  Renders a role badge with appropriate styling based on role type.

  ## Attributes
  - `role` - Role struct with name and is_system_role fields
  - `size` - Badge size: :xs, :sm, :md, :lg (default: :md)
  - `class` - Additional CSS classes

  ## Examples

      <.role_badge role={user.role} />
      <.role_badge role={role} size={:sm} />
      <.role_badge role={custom_role} class="ml-2" />
  """
  attr :role, :map, required: true
  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg]
  attr :class, :string, default: ""

  def role_badge(assigns) do
    ~H"""
    <span class={["badge", role_class(@role), size_class(@size), @class]}>
      {@role.name}
    </span>
    """
  end

  @doc """
  Renders a user status badge (active/inactive/unconfirmed).

  ## Attributes
  - `is_active` - Boolean user active status
  - `confirmed_at` - DateTime of email confirmation or nil
  - `size` - Badge size (default: :md)

  ## Examples

      <.user_status_badge is_active={user.is_active} confirmed_at={user.confirmed_at} />
      <.user_status_badge is_active={false} confirmed_at={nil} size={:sm} />
  """
  attr :is_active, :boolean, required: true
  attr :confirmed_at, :any, default: nil
  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg]

  def user_status_badge(assigns) do
    ~H"""
    <span class={["badge", status_class(@is_active, @confirmed_at), size_class(@size)]}>
      {status_text(@is_active, @confirmed_at)}
    </span>
    """
  end

  @doc """
  Renders a code status badge for referral codes.

  ## Attributes
  - `code` - Code struct with uses_count, max_uses, and expiration_date fields
  - `size` - Badge size (default: :md)

  ## Examples

      <.code_status_badge code={referral_code} />
      <.code_status_badge code={code} size={:sm} />
  """
  attr :code, :map, required: true
  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg]

  def code_status_badge(assigns) do
    ~H"""
    <span class={["badge", code_status_class(@code), size_class(@size)]}>
      {code_status_text(@code)}
    </span>
    """
  end

  # Private helper functions

  # Role badge classes
  defp role_class(%{is_system_role: true, name: "Owner"}), do: "badge-error"
  defp role_class(%{is_system_role: true, name: "Admin"}), do: "badge-warning"
  defp role_class(%{is_system_role: true, name: "User"}), do: "badge-info"
  defp role_class(%{is_system_role: true}), do: "badge-accent"
  defp role_class(%{is_system_role: false}), do: "badge-primary"
  defp role_class(_), do: "badge-ghost"

  # User status classes
  defp status_class(false, _), do: "badge-ghost"
  defp status_class(true, nil), do: "badge-warning"
  defp status_class(true, _), do: "badge-success"

  # User status text
  defp status_text(false, _), do: "Inactive"
  defp status_text(true, nil), do: "Unconfirmed"
  defp status_text(true, _), do: "Active"

  # Code status for referral codes
  defp code_status_class(code) do
    cond do
      code.number_of_uses >= code.max_uses ->
        "badge-error"

      code.expiration_date &&
          DateTime.compare(DateTime.utc_now(), code.expiration_date) == :gt ->
        "badge-warning"

      true ->
        "badge-success"
    end
  end

  defp code_status_text(code) do
    cond do
      code.number_of_uses >= code.max_uses ->
        "Expired"

      code.expiration_date && DateTime.compare(DateTime.utc_now(), code.expiration_date) == :gt ->
        "Expired"

      true ->
        "Active"
    end
  end

  @doc """
  Renders a category badge for email templates.

  ## Attributes
  - `category` - Template category: "system", "marketing", "transactional"
  - `size` - Badge size (default: :sm)
  - `class` - Additional CSS classes

  ## Examples

      <.category_badge category="system" />
      <.category_badge category="marketing" size={:md} />
  """
  attr :category, :string, required: true
  attr :size, :atom, default: :sm, values: [:xs, :sm, :md, :lg]
  attr :class, :string, default: ""

  def category_badge(assigns) do
    ~H"""
    <div class={["badge", category_class(@category), size_class(@size), @class]}>
      {String.capitalize(@category)}
    </div>
    """
  end

  @doc """
  Renders a status badge for email templates.

  ## Attributes
  - `status` - Template status: "active", "draft", "archived"
  - `size` - Badge size (default: :sm)
  - `class` - Additional CSS classes

  ## Examples

      <.template_status_badge status="active" />
      <.template_status_badge status="draft" size={:md} />
  """
  attr :status, :string, required: true
  attr :size, :atom, default: :sm, values: [:xs, :sm, :md, :lg]
  attr :class, :string, default: ""

  def template_status_badge(assigns) do
    ~H"""
    <div class={["badge", template_status_class(@status), size_class(@size), @class]}>
      {String.capitalize(@status)}
    </div>
    """
  end

  # Template category classes
  defp category_class("system"), do: "badge-info"
  defp category_class("marketing"), do: "badge-secondary"
  defp category_class("transactional"), do: "badge-primary"
  defp category_class(_), do: "badge-ghost"

  # Template status classes
  defp template_status_class("active"), do: "badge-success"
  defp template_status_class("draft"), do: "badge-warning"
  defp template_status_class("archived"), do: "badge-ghost"
  defp template_status_class(_), do: "badge-neutral"

  # Size classes
  defp size_class(:xs), do: "badge-xs"
  defp size_class(:sm), do: "badge-sm"
  defp size_class(:md), do: "badge-md"
  defp size_class(:lg), do: "badge-lg"
end
