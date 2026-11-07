defmodule PhoenixKitWeb.Components.Core.RoleSwitcher do
  @moduledoc """
  The switcher for the role a user acts as (`PhoenixKit.Users.ActiveRole`).

  Renders nothing unless the scope is narrowed — the switcher is on and the
  user holds two or more switchable roles. An impersonation session gets the
  switcher like any other: the role lives on the session token, so switching
  there never touches the borrowed account's own sessions. Every row is a
  plain form `PUT` to `/users/session/role`, like the account switcher: this
  renders in layouts, where a `phx-click` would land in whichever LiveView the
  page mounted.

  Reads only the scope: the switchable roles are loaded once by
  `PhoenixKit.Users.Auth.Scope.for_user/1`, so rendering on every page costs no
  query.

  ## Variants

    * `:menu_section` — a "Role" section for an account dropdown's `<ul
      class="menu">`. Always rendered where the switcher is visible, except
      that with the switcher placed in the header it shows only below the `sm`
      breakpoint, where the header control is hidden.
    * `:header` — a compact dropdown for a header bar, rendered only when
      `role_switcher_location` is `"header"`, and only from `sm` up.

  Render both, once each, and the location setting decides which one a
  visitor sees at which width:

      <.role_switcher variant={:header} id="admin-role-switcher-header" scope={@scope} ... />
      <.role_switcher variant={:menu_section} id="admin-role-switcher-menu" scope={@scope} ... />
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Users.ActiveRole
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.Icon
  alias PhoenixKitWeb.Components.Core.Icons

  @doc """
  Renders the role switcher.

  ## Attributes

    * `:scope` — the current scope. Renders nothing unless it is narrowed.
    * `:id` — unique per placement; prefixes every form id.
    * `:variant` — `:menu_section` (default) or `:header`.
    * `:current_path` — sent as `return_to`, so the switch comes back here when
      the new role can reach it.
    * `:current_locale` — keeps the form's action on the visitor's locale.
    * `:location` — `:menu` or `:header`. `nil` (default) reads the
      `role_switcher_location` setting; pass it to render without a settings
      read.
  """
  attr :scope, :any, default: nil
  attr :id, :string, required: true
  attr :variant, :atom, default: :menu_section, values: [:menu_section, :header]
  attr :current_path, :string, default: ""
  attr :current_locale, :string, default: nil
  attr :location, :atom, default: nil, values: [nil, :menu, :header]

  def role_switcher(assigns) do
    assigns |> assign_state() |> render_switcher()
  end

  defp assign_state(assigns) do
    scope = assigns.scope
    roles = Scope.switchable_roles(scope)
    active = Scope.active_role(scope)
    visible? = not is_nil(active) and match?([_, _ | _], roles)

    # The setting is read only for a visitor who will see the switcher.
    location = if visible?, do: assigns.location || ActiveRole.location(), else: :menu

    assigns
    |> assign(:roles, roles)
    |> assign(:active, active)
    |> assign(:visible?, visible?)
    |> assign(:location, location)
  end

  defp render_switcher(%{visible?: false} = assigns), do: ~H""

  defp render_switcher(%{variant: :header, location: :menu} = assigns), do: ~H""

  defp render_switcher(%{variant: :header} = assigns) do
    ~H"""
    <div id={@id} class="dropdown dropdown-end hidden sm:block">
      <div
        tabindex="0"
        role="button"
        class="btn btn-sm btn-ghost gap-1 font-normal"
        title={gettext("Switch role")}
        aria-label={gettext("Switch role")}
      >
        <Icon.icon name="hero-identification" class="w-4 h-4" />
        <span class="max-w-40 truncate">{@active.name}</span>
        <Icon.icon name="hero-chevron-down" class="w-3 h-3 opacity-60" />
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-100 rounded-box z-[60] w-56 p-2 shadow-xl border border-base-300 mt-3 flex-nowrap"
      >
        <li class="menu-title px-4 py-1">
          <span class="text-xs">{gettext("Act as")}</span>
        </li>
        <.role_rows
          id={@id}
          roles={@roles}
          active={@active}
          current_path={@current_path}
          current_locale={@current_locale}
        />
      </ul>
    </div>
    """
  end

  defp render_switcher(%{variant: :menu_section} = assigns) do
    assigns =
      assign(assigns, :responsive, if(assigns.location == :header, do: "sm:hidden"))

    ~H"""
    <div class={["divider my-0", @responsive]}></div>
    <li class={["menu-title px-4 py-1", @responsive]}>
      <span class="text-xs">{gettext("Role")}</span>
    </li>
    <.role_rows
      id={@id}
      roles={@roles}
      active={@active}
      current_path={@current_path}
      current_locale={@current_locale}
      class={@responsive}
    />
    """
  end

  # One row per switchable role. Same structure as the account rows in the
  # account dropdowns: the wrapper div is the only `li > *` and carries the
  # reset for daisyUI's menu-item padding, so the active row (a div) and the
  # others (form buttons) line up.
  attr :id, :string, required: true
  attr :roles, :list, required: true
  attr :active, :map, required: true
  attr :current_path, :string, required: true
  attr :current_locale, :string, default: nil
  attr :class, :any, default: nil

  defp role_rows(assigns) do
    ~H"""
    <li :for={role <- @roles} class={["p-0", @class]}>
      <div class="!p-0 flex items-center min-w-0 !bg-transparent hover:!bg-transparent focus:!bg-transparent">
        <%= if role.uuid == @active.uuid do %>
          <div class="flex w-full min-w-0 items-center gap-2 rounded-lg bg-primary px-4 py-2 text-primary-content">
            <span class="flex-1 min-w-0 truncate" title={Roles.display_name(role)}>{Roles.display_name(role)}</span>
            <Icons.icon_check class="w-4 h-4 shrink-0" />
          </div>
        <% else %>
          <.form
            for={%{}}
            id={"#{@id}-#{role.uuid}"}
            action={Routes.locale_aware_path(assigns, "/users/session/role")}
            method="put"
            class="flex-1 min-w-0"
          >
            <input type="hidden" name="role_uuid" value={role.uuid} />
            <input type="hidden" name="return_to" value={@current_path} />
            <%!-- `text-start`: a <button> inherits `text-align: center`,
                 which would pull a short name off the active row's edge. --%>
            <button
              type="submit"
              class="flex w-full min-w-0 items-center gap-2 rounded-lg px-4 py-2 text-start hover:bg-base-200"
            >
              <span class="flex-1 min-w-0 truncate" title={Roles.display_name(role)}>{Roles.display_name(role)}</span>
              <span class="w-4 shrink-0" aria-hidden="true"></span>
            </button>
          </.form>
        <% end %>
      </div>
    </li>
    """
  end
end
