defmodule PhoenixKitWeb.Components.Core.OrganizationSwitcher do
  @moduledoc "The root person's organizations, independent of ordinary account switching."
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  attr :scope, :any, default: nil
  attr :id, :string, required: true
  attr :current_path, :string, default: ""
  attr :current_locale, :string, default: nil

  def organization_switcher(assigns) do
    assigns =
      assigns
      |> assign(
        :organizations,
        if(assigns.scope, do: assigns.scope.acting_organizations, else: [])
      )
      |> assign(:acting?, not is_nil(Scope.acting_user_uuid(assigns.scope)))

    ~H"""
    <li :if={@organizations != [] or @acting?} class="menu-title px-4 py-1">
      <span class="text-xs">{gettext("Acting as")}</span>
    </li>
    <li :if={@organizations != [] or @acting?}>
      <form
        id={"#{@id}-leave"}
        action={Routes.path("/users/session/organization", locale: @current_locale)}
        method="post"
        class="!block !p-0"
      >
        <input type="hidden" name="_method" value="delete" />
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <input type="hidden" name="return_to" value={@current_path} />
        <button class="w-full text-left px-4 py-2 rounded-lg hover:bg-base-200">
          <%= if @acting? do %>
            {gettext("Back to my account")}
          <% else %>
            <span :if={@scope.user.uuid == @scope.organization_root.uuid} aria-hidden="true">● </span>{PhoenixKit.Users.Auth.User.display_name(
              @scope.organization_root
            )} ({gettext("My account")})
          <% end %>
        </button>
      </form>
    </li>
    <li :for={organization <- @organizations}>
      <form
        id={"#{@id}-#{organization.uuid}"}
        action={
          Routes.path("/users/session/organizations/#{organization.uuid}", locale: @current_locale)
        }
        method="post"
        class="!block !p-0"
      >
        <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
        <button class={[
          "w-full text-left px-4 py-2 rounded-lg hover:bg-base-200",
          @scope.user.uuid == organization.uuid && "font-semibold"
        ]}>
          <span :if={@scope.user.uuid == organization.uuid} aria-hidden="true">● </span>{organization.name}
        </button>
      </form>
    </li>
    """
  end
end
